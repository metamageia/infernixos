"""Durable Hermes-backed jobs: identity, checkpoint, logs, resume, cancel.

A job is a named request decomposed into phases. Each phase runs the real
upstream oneshot CLI (``hermes -z``) in the foreground — nothing here starts
inference in the background — and appends the returned session id to the
job's durable record so a later ``hermes --resume <session_id>`` continues
the same conversation. State is written atomically before and after each
phase so an interrupted run always resumes from the last completed phase.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from .state import State, StateError, read_json, write_json_atomic

JOB_VERSION = 1
HERMES_BIN_ENV = "INFERNIXOS_HERMES_BIN"
USAGE_ENV = "INFERNIXOS_JOB_USAGE_DIR"

PHASE_PENDING = "pending"
PHASE_RUNNING = "running"
PHASE_DONE = "done"
PHASE_FAILED = "failed"
PHASE_CANCELLED = "cancelled"

JOB_RUNNING = "running"
JOB_COMPLETED = "completed"
JOB_FAILED = "failed"
JOB_CANCELLED = "cancelled"
JOB_INTERRUPTED = "interrupted"


class JobError(Exception):
    pass


def _hermes_bin() -> str:
    return os.environ.get(HERMES_BIN_ENV) or "hermes"


def new_job_id(name: str) -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    slug = re.sub(r"[^a-z0-9-]+", "-", name.lower()).strip("-")[:32] or "job"
    digest = hashlib.sha256(f"{time.time_ns()}{name}".encode()).hexdigest()[:8]
    return f"{stamp}-{slug}-{digest}"


def safe_job_id(job_id: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9._-]+", job_id) or ".." in job_id:
        raise JobError(f"invalid job id: {job_id!r}")
    return job_id


class JobStore:
    def __init__(self, state: State):
        self.state = state
        self.jobs_dir = state.jobs_dir

    def _dir(self, job_id: str) -> Path:
        try:
            d = self.state.job_dir(safe_job_id(job_id))
        except StateError as exc:
            raise JobError(str(exc)) from exc
        return d

    def _record_path(self, job_id: str) -> Path:
        return self._dir(job_id) / "job.json"

    def create(
        self,
        name: str,
        request_id: str,
        phases: list[dict],
        metadata: dict | None = None,
    ) -> dict:
        if not name or not request_id:
            raise JobError("name and request_id are required")
        if not phases:
            raise JobError("a job needs at least one phase")
        for p in phases:
            if not isinstance(p, dict) or not p.get("name") or not p.get("prompt"):
                raise JobError("each phase needs name and prompt")
        job_id = new_job_id(name)
        d = self._dir(job_id)
        d.mkdir(parents=True, exist_ok=True)
        record = {
            "version": JOB_VERSION,
            "job_id": job_id,
            "name": name,
            "request_id": request_id,
            "request_digest": hashlib.sha256(
                json.dumps({"name": name, "request_id": request_id, "phases": phases}, sort_keys=True).encode()
            ).hexdigest(),
            "created": datetime.now(timezone.utc).isoformat(),
            "status": JOB_RUNNING,
            "phases": [
                {
                    "name": p["name"],
                    "prompt": p["prompt"],
                    "state": PHASE_PENDING,
                    "session_id": None,
                    "started": None,
                    "finished": None,
                    "error": None,
                }
                for p in phases
            ],
            "metadata": dict(metadata or {}),
        }
        write_json_atomic(self._record_path(job_id), record)
        (d / "log.txt").touch()
        return record

    def load(self, job_id: str) -> dict:
        rec = read_json(self._record_path(job_id))
        if rec is None:
            raise JobError(f"no such job: {job_id}")
        return rec

    def save(self, job_id: str, record: dict) -> None:
        write_json_atomic(self._record_path(job_id), record)

    def append_log(self, job_id: str, line: str) -> None:
        with open(self._dir(job_id) / "log.txt", "a", encoding="utf-8") as f:
            f.write(line.rstrip("\n") + "\n")

    def status(self, job_id: str) -> dict:
        rec = self.load(job_id)
        return {
            "job_id": rec["job_id"],
            "name": rec["name"],
            "request_id": rec["request_id"],
            "status": rec["status"],
            "phases": [
                {k: p[k] for k in ("name", "state", "session_id", "error")}
                for p in rec["phases"]
            ],
        }

    def cancel(self, job_id: str) -> dict:
        rec = self.load(job_id)
        if rec["status"] == JOB_COMPLETED:
            raise JobError("job already completed; nothing to cancel")
        (self._dir(job_id) / "cancel.flag").write_text(datetime.now(timezone.utc).isoformat() + "\n")
        return self.load(job_id)

    def _cancelled(self, job_id: str) -> bool:
        return (self._dir(job_id) / "cancel.flag").exists()

    def _usage_path(self, job_id: str, phase: str) -> Path:
        base = os.environ.get(USAGE_ENV)
        d = Path(base) if base else self._dir(job_id) / "usage"
        d.mkdir(parents=True, exist_ok=True)
        return d / f"{re.sub(r'[^a-z0-9-]+', '-', phase.lower())}.json"

    def _run_phase(self, job_id: str, record: dict, index: int) -> None:
        phase = record["phases"][index]
        job_dir = self._dir(job_id)
        usage_file = self._usage_path(job_id, phase["name"])
        if usage_file.exists():
            usage_file.unlink()
        phase["state"] = PHASE_RUNNING
        phase["started"] = datetime.now(timezone.utc).isoformat()
        phase["error"] = None
        self.save(job_id, record)
        self.append_log(job_id, f"[phase] {phase['name']} started {phase['started']}")
        cmd = [
            _hermes_bin(),
            "-z",
            "--usage-file",
            str(usage_file),
            phase["prompt"],
        ]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
        except FileNotFoundError as exc:
            phase["state"] = PHASE_FAILED
            phase["error"] = f"hermes binary not found: {_hermes_bin()}"
            phase["finished"] = datetime.now(timezone.utc).isoformat()
            record["status"] = JOB_FAILED
            self.save(job_id, record)
            self.append_log(job_id, f"[error] {phase['error']}")
            raise JobError(phase["error"]) from exc
        self.append_log(job_id, proc.stdout)
        if proc.stderr.strip():
            self.append_log(job_id, "[stderr] " + proc.stderr.strip())
        if proc.returncode != 0:
            phase["state"] = PHASE_FAILED
            phase["error"] = f"exit code {proc.returncode}"
            phase["finished"] = datetime.now(timezone.utc).isoformat()
            record["status"] = JOB_FAILED
            self.save(job_id, record)
            self.append_log(job_id, f"[error] phase {phase['name']} {phase['error']}")
            raise JobError(f"phase {phase['name']} failed: exit {proc.returncode}")
        session_id = None
        try:
            session_id = json.loads(usage_file.read_text()).get("session_id")
        except (OSError, json.JSONDecodeError):
            pass
        phase["state"] = PHASE_DONE
        phase["session_id"] = session_id
        phase["finished"] = datetime.now(timezone.utc).isoformat()
        self.save(job_id, record)
        self.append_log(job_id, f"[phase] {phase['name']} done session={session_id}")

    def run(self, job_id: str) -> dict:
        """Run (or resume) a job. Only pending/failed phases execute; a
        previously running phase whose process died is marked interrupted and
        rerun. Duplicate side effects are the caller's phases' concern: the
        record carries request_digest so idempotent consumers can key on it."""
        record = self.load(job_id)
        if record["status"] == JOB_COMPLETED:
            raise JobError("job already completed")
        if self._cancelled(job_id) and record["status"] != JOB_CANCELLED:
            record["status"] = JOB_CANCELLED
            for p in record["phases"]:
                if p["state"] in (PHASE_PENDING, PHASE_RUNNING):
                    p["state"] = PHASE_CANCELLED
            self.save(job_id, record)
            return record
        record["status"] = JOB_RUNNING
        self.save(job_id, record)
        for i, phase in enumerate(record["phases"]):
            if phase["state"] == PHASE_RUNNING:
                phase["error"] = "interrupted run; restarting phase"
                self.append_log(job_id, f"[recover] phase {phase['name']} interrupted")
            if phase["state"] in (PHASE_PENDING, PHASE_FAILED, PHASE_RUNNING):
                if self._cancelled(job_id):
                    record["status"] = JOB_CANCELLED
                    for p in record["phases"][i:]:
                        if p["state"] in (PHASE_PENDING, PHASE_RUNNING):
                            p["state"] = PHASE_CANCELLED
                    self.save(job_id, record)
                    self.append_log(job_id, "[cancel] job cancelled")
                    return record
                self._run_phase(job_id, record, i)
        record["status"] = JOB_COMPLETED
        self.save(job_id, record)
        return record

    def list_jobs(self) -> list[dict]:
        out = []
        if not self.jobs_dir.exists():
            return out
        for d in sorted(self.jobs_dir.iterdir()):
            rec = read_json(d / "job.json")
            if rec:
                out.append(self.status(rec["job_id"]))
        return out
