"""Durable, versioned runtime state store for the infernixos runtime.

State lives under a single root directory. A version manifest records the
owner of the state, the runtime version that wrote it, the configured
machine source (git flake target), the writable extension workspace, and the
set of immutable root health-check commands. Generated app state is kept
separate from code and install manifests.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path

STATE_VERSION = 1
ENV_ROOT = "INFERNIXOS_STATE"


def _default_root() -> Path:
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(base) / "infernixos"


class StateError(Exception):
    pass


def safe_join(root: Path, *parts: str) -> Path:
    """Join *parts* onto *root*, rejecting absolute parts, '..', and symlink
    escape. Raises StateError on any unsafe segment."""
    for p in parts:
        if not p or p in (".", ".."):
            raise StateError(f"unsafe path segment: {p!r}")
        if os.path.isabs(p):
            raise StateError(f"absolute path segment: {p!r}")
        if "/" in p or "\\" in p:
            raise StateError(f"nested path segment: {p!r}")
    out = root.joinpath(*parts)
    res = out.resolve(strict=False)
    root_res = root.resolve(strict=False)
    if res != root_res and root_res not in res.parents:
        raise StateError(f"path escapes state root: {out}")
    return out


class State:
    """Wraps the runtime state root and its version manifest."""

    def __init__(self, root: Path | None = None):
        self.root = (root or _default_root()).expanduser()
        self.manifest_path = self.root / "manifest.json"
        self.jobs_dir = self.root / "jobs"
        self.extensions_dir = self.root / "extensions"
        self.backups_dir = self.root / "backups"
        self.activations_dir = self.root / "activations"
        self.lock_dir = self.root / "locks"

    def init(
        self,
        machine_source: str,
        flake_target: str,
        extension_workspace: str,
        health_commands: list[str] | None = None,
        force: bool = False,
    ) -> dict:
        """Create the state root and write the version manifest. Raises
        StateError if the root already holds a manifest and force is unset."""
        if self.manifest_path.exists() and not force:
            raise StateError(
                f"state already initialized at {self.root} (manifest present); "
                "pass force=True to re-init"
            )
        for d in (
            self.root,
            self.jobs_dir,
            self.extensions_dir,
            self.backups_dir,
            self.activations_dir,
            self.lock_dir,
        ):
            d.mkdir(parents=True, exist_ok=True)
        manifest = {
            "version": STATE_VERSION,
            "runtime": "infernixos",
            "created": datetime.now(timezone.utc).isoformat(),
            "machine_source": machine_source,
            "flake_target": flake_target,
            "extension_workspace": extension_workspace,
            "health_commands": list(health_commands or []),
        }
        self._write_atomic(self.manifest_path, manifest)
        return manifest

    def manifest(self) -> dict:
        if not self.manifest_path.exists():
            raise StateError(f"state not initialized at {self.root}; run init")
        return json.loads(self.manifest_path.read_text())

    def machine_source(self) -> str:
        return self.manifest()["machine_source"]

    def flake_target(self) -> str:
        return self.manifest()["flake_target"]

    def extension_workspace(self) -> Path:
        ws = self.manifest()["extension_workspace"]
        return Path(ws).expanduser()

    def health_commands(self) -> list[str]:
        return list(self.manifest().get("health_commands", []))

    def extension_dir(self, name: str) -> Path:
        return safe_join(self.extensions_dir, name)

    def job_dir(self, job_id: str) -> Path:
        return safe_join(self.jobs_dir, job_id)

    def activation_dir(self, generation: str) -> Path:
        return safe_join(self.activations_dir, generation)

    @staticmethod
    def _write_atomic(path: Path, data) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2, sort_keys=True)
                f.write("\n")
            os.replace(tmp, path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)


def write_json_atomic(path: Path, data) -> None:
    State._write_atomic(path, data)


def read_json(path: Path, default=None):
    if not path.exists():
        return default
    return json.loads(path.read_text())
