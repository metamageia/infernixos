"""Privileged activation: separate the conversational agent from root.

The runtime (unprivileged) builds a system closure candidate and records a
candidate record containing: the exact immutable closure out path, the
configured flake target, the expected base generation, a digest over the
record, and the human approval state. Approval NEVER comes from the agent:
``approve`` re-verifies the record fields against arguments the human (or a
polkit-authorized helper acting for the human) supplies, marks the record
approved with the OS uid that did it, and prints the exact immutable
activation command. The command invokes the installed root helper
(``infernixos-activate``) with only the candidate id — the helper re-reads
and re-verifies the immutable record at run time. Health-check commands are
taken from the immutable state manifest, never from any request payload.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from .state import State, StateError, safe_join, read_json, write_json_atomic

CANDIDATE_VERSION = 1
APPROVE_MODE_ENV = "INFERNIXOS_ACTIVATE_HELPER"
ACTIVATION_RECORD_SCHEMA = "infernixos.activation/1"


class ActivationError(Exception):
    pass


def _new_candidate_id() -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    digest = hashlib.sha256(f"{time_ns()}{os.urandom(8)}".encode()).hexdigest()[:8]
    return f"candidate-{stamp}-{digest}"


def time_ns() -> int:
    import time
    return time.time_ns()


def _check_out_path(p: str) -> str:
    if not re.fullmatch(r"/nix/store/[a-z0-9]{32}-[A-Za-z0-9._+-]+", p):
        raise ActivationError(f"not an immutable store path: {p!r}")
    return p


class ActivationStore:
    def __init__(self, state: State):
        self.state = state
        self.dir = state.activations_dir

    def record_path(self, candidate_id: str) -> Path:
        try:
            return safe_join(self.dir, candidate_id) / "record.json"
        except StateError as exc:
            raise ActivationError(str(exc)) from exc

    def create_request(self, label: str, closure: str, expected_base: str) -> dict:
        _check_out_path(closure)
        _check_out_path(expected_base)
        cid = _new_candidate_id()
        record = {
            "schema": ACTIVATION_RECORD_SCHEMA,
            "version": CANDIDATE_VERSION,
            "candidate_id": cid,
            "label": label,
            "closure": closure,
            "flake_target": self.state.flake_target(),
            "expected_base_generation": expected_base,
            "health_commands": self.state.health_commands(),
            "requested_by_uid": os.getuid(),
            "requested": datetime.now(timezone.utc).isoformat(),
            "status": "requested",
            "approved_by_uid": None,
            "approved": None,
            "activated": None,
            "result": None,
        }
        record["record_digest"] = self._digest(record)
        p = self.record_path(cid)
        p.parent.mkdir(parents=True, exist_ok=True)
        write_json_atomic(p, record)
        return record

    @staticmethod
    def _digest(record: dict) -> str:
        core = {k: v for k, v in record.items() if k not in ("record_digest",)}
        return hashlib.sha256(
            json.dumps(core, sort_keys=True).encode()
        ).hexdigest()

    def load(self, candidate_id: str) -> dict:
        rec = read_json(self.record_path(candidate_id))
        if rec is None:
            raise ActivationError(f"no such candidate: {candidate_id}")
        digest = rec.get("record_digest")
        if digest and digest != self._digest({k: v for k, v in rec.items() if k != "record_digest"}):
            raise ActivationError(f"candidate record integrity failure: {candidate_id}")
        return rec

    def verify_and_prepare(self, candidate_id: str, closure: str, expected_base: str) -> dict:
        """Human-approval gate: re-verify exact immutable fields against the
        arguments supplied by the approver (not agent-asserted). Marks the
        record approved by the CURRENT OS uid."""
        rec = self.load(candidate_id)
        if rec["status"] == "activated":
            raise ActivationError("candidate already activated")
        if rec["closure"] != _check_out_path(closure):
            raise ActivationError(
                f"closure mismatch: record says {rec['closure']}, approver passed {closure}"
            )
        if rec["expected_base_generation"] != _check_out_path(expected_base):
            raise ActivationError("expected base generation mismatch")
        if rec["flake_target"] != self.state.flake_target():
            raise ActivationError("configured flake target changed since request")
        if rec["record_digest"] != self._digest({k: v for k, v in rec.items() if k != "record_digest"}):
            raise ActivationError("record tampered")
        rec["status"] = "approved"
        rec["approved_by_uid"] = os.getuid()
        rec["approved"] = datetime.now(timezone.utc).isoformat()
        rec["record_digest"] = self._digest(rec)
        write_json_atomic(self.record_path(candidate_id), rec)
        return rec

    def list_candidates(self) -> list[dict]:
        if not self.dir.exists():
            return []
        out = []
        for d in sorted(self.dir.iterdir()):
            rec = read_json(d / "record.json")
            if rec:
                out.append({
                    "candidate_id": rec["candidate_id"],
                    "label": rec["label"],
                    "closure": rec["closure"],
                    "status": rec["status"],
                    "requested": rec["requested"],
                })
        return out

    def preflight(self, rec: dict) -> None:
        """Verify the environment still matches the record before side
        effects: exact closure exists, base generation matches, digest holds."""
        if rec["status"] != "approved":
            raise ActivationError("candidate is not approved")
        closure = Path(rec["closure"])
        if not closure.exists():
            raise ActivationError(f"closure missing: {closure}")
        base = rec["expected_base_generation"]
        link = Path("/run/current-system")
        try:
            current = link.resolve()
        except OSError:
            current = None
        if current is not None and str(current) != base:
            raise ActivationError(
                f"base generation moved: expected {base}, current is {current}"
            )
        if rec["record_digest"] != self._digest({k: v for k, v in rec.items() if k != "record_digest"}):
            raise ActivationError("record tampered")

    def mark_activated(self, candidate_id: str, result: dict) -> dict:
        rec = self.load(candidate_id)
        rec["status"] = "activated" if result.get("ok") else "failed"
        rec["activated"] = datetime.now(timezone.utc).isoformat()
        rec["result"] = result
        rec["record_digest"] = self._digest(rec)
        write_json_atomic(self.record_path(candidate_id), rec)
        return rec


def activation_command(rec: dict) -> str:
    """The exact immutable command an authorized human runs (via sudo/polkit).
    Takes only the candidate id; the root helper re-verifies the immutable
    record itself and runs health commands from the manifest."""
    helper = os.environ.get(APPROVE_MODE_ENV) or "sudo infernixos-activate"
    return f"{helper} {rec['candidate_id']}"


def run_activation(store: ActivationStore, candidate_id: str) -> dict:
    """Root-side execution path (infernixos-activate). Runs ONLY after
    preflight passes; health commands come from the immutable record, which
    came from the state manifest, never from a request payload."""
    rec = store.load(candidate_id)
    store.preflight(rec)
    activation_id = f"{rec['candidate_id']}"
    store.state.activation_dir(activation_id).mkdir(parents=True, exist_ok=True)
    log = store.state.activation_dir(activation_id) / "health.log"
    failures = []
    with open(log, "w", encoding="utf-8") as f:
        for cmd in rec["health_commands"]:
            f.write(f"$ {cmd}\n")
            f.flush()
            try:
                proc = subprocess.run(
                    cmd, shell=True, capture_output=True, text=True, timeout=120
                )
                f.write(proc.stdout)
                if proc.stderr.strip():
                    f.write(proc.stderr)
                if proc.returncode != 0:
                    failures.append({"command": cmd, "code": proc.returncode})
            except subprocess.TimeoutExpired:
                failures.append({"command": cmd, "code": "timeout"})
    result = {"ok": not failures, "failures": failures, "log": str(log)}
    store.mark_activated(candidate_id, result)
    return result
