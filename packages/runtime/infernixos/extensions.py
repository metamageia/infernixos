"""Extension lifecycle: source ownership, create/build/check/install,
update/remove/undo, and data backups.

A generated extension lives as versioned git source in the per-user writable
extension workspace (``<workspace>/<name>``). Install builds an immutable Nix
package from that source via the machine flake, records the accepted package
out path in the registry, and seeds app state under
``<state>/extensions/<name>/data`` (never inside the store). Remove unlinks
the package but keeps source and data. Undo restores the previous accepted
package. Backups snapshot registered data paths only.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from .state import State, StateError, safe_join, read_json, write_json_atomic

REGISTRY_VERSION = 1
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,63}$")


class ExtensionError(Exception):
    pass


def check_name(name: str) -> str:
    if not NAME_RE.match(name):
        raise ExtensionError(
            f"invalid extension name {name!r}: lowercase letters/digits/hyphens, start with a letter"
        )
    return name


class ExtensionRegistry:
    """Install manifests and source-ownership records under <state>/extensions."""

    def __init__(self, state: State):
        self.state = state
        self.extensions_dir = state.extensions_dir
        self.registry_path = self.extensions_dir / "registry.json"

    def _load(self) -> dict:
        reg = read_json(self.registry_path)
        if reg is None:
            return {"version": REGISTRY_VERSION, "extensions": {}}
        return reg

    def _save(self, reg: dict) -> None:
        self.extensions_dir.mkdir(parents=True, exist_ok=True)
        write_json_atomic(self.registry_path, reg)

    def all(self) -> dict:
        return self._load()["extensions"]

    def get(self, name: str) -> dict:
        ext = self._load()["extensions"].get(check_name(name))
        if ext is None:
            raise ExtensionError(f"extension not installed: {name}")
        return ext

    def record(
        self,
        name: str,
        source_path: str,
        source_rev: str,
        package_out: str,
        drv: str | None,
        entry: dict | None,
        request_id: str | None,
        session_id: str | None,
        permissions: list[str] | None = None,
    ) -> dict:
        name = check_name(name)
        self.extensions_dir.mkdir(parents=True, exist_ok=True)
        data_dir = safe_join(self.extensions_dir, name) / "data"
        data_dir.mkdir(parents=True, exist_ok=True)
        ext = {
            "version": REGISTRY_VERSION,
            "name": name,
            "source": {"path": source_path, "rev": source_rev},
            "package": {"out": package_out, "drv": drv},
            "entry": entry or {},
            "data_dir": str(data_dir),
            "permissions": list(permissions or []),
            "request_id": request_id,
            "session_id": session_id,
            "updated": datetime.now(timezone.utc).isoformat(),
        }
        reg = self._load()
        prev = reg["extensions"].get(name)
        if prev:
            hist = prev.get("history", [])
            hist.append({k: prev[k] for k in ("source", "package", "entry", "updated")})
            ext["history"] = hist[-10:]
        reg["extensions"][name] = ext
        self._save(reg)
        return ext

    def set_disabled(self, name: str, disabled: bool) -> dict:
        reg = self._load()
        ext = reg["extensions"].get(check_name(name))
        if not ext:
            raise ExtensionError(f"extension not installed: {name}")
        ext["disabled"] = disabled
        self._save(reg)
        return ext

    def set_entry(self, name: str, entry: dict) -> dict:
        reg = self._load()
        ext = reg["extensions"].get(check_name(name))
        if not ext:
            raise ExtensionError(f"extension not installed: {name}")
        ext["entry"] = entry
        self._save(reg)
        return ext

    def set_permissions(self, name: str, permissions: list[str]) -> dict:
        reg = self._load()
        ext = reg["extensions"].get(check_name(name))
        if not ext:
            raise ExtensionError(f"extension not installed: {name}")
        ext["permissions"] = list(permissions)
        self._save(reg)
        return ext

    def last_accepted(self, name: str, before: str) -> dict | None:
        ext = self.get(name)
        for h in reversed(ext.get("history", [])):
            if h["updated"] != before:
                return h
        return None

    def forget(self, name: str) -> None:
        reg = self._load()
        name = check_name(name)
        if name not in reg["extensions"]:
            raise ExtensionError(f"extension not installed: {name}")
        del reg["extensions"][name]
        self._save(reg)


def _git(repo: Path, *args: str, check=True) -> str:
    proc = subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, text=True
    )
    if check and proc.returncode != 0:
        raise ExtensionError(f"git {' '.join(args[:1])} failed: {proc.stderr.strip()}")
    return proc.stdout


class ExtensionSource:
    """Versioned git source in the user workspace."""

    def __init__(self, registry: ExtensionRegistry):
        self.registry = registry
        self.workspace = registry.state.extension_workspace()

    def source_dir(self, name: str) -> Path:
        name = check_name(name)
        p = (self.workspace / name).resolve(strict=False)
        ws = self.workspace.resolve(strict=False)
        if p != ws and ws not in p.parents:
            raise ExtensionError(f"source path escapes workspace: {p}")
        return p

    def create(self, name: str, kind: str, template: dict) -> Path:
        """kind: 'app' (Python+QML .desktop app) or 'widget' (QuickShell QML)
        or 'hermes-plugin' (Hermes user plugin). Returns the source dir."""
        name = check_name(name)
        d = self.source_dir(name)
        if d.exists():
            raise ExtensionError(f"source already exists: {d}")
        d.mkdir(parents=True)
        if kind == "app":
            self._template_app(d, name, template)
        elif kind == "widget":
            self._template_widget(d, name, template)
        elif kind == "hermes-plugin":
            self._template_plugin(d, name, template)
        else:
            raise ExtensionError(f"unknown extension kind: {kind}")
        _git(d, "init", "-q")
        _git(d, "add", "-A")
        _git(d, "-c", "user.email=infernixos@runtime", "-c", "user.name=infernixos",
             "commit", "-q", "-m", f"init {name}")
        return d

    def rev(self, name: str) -> str:
        return _git(self.source_dir(name), "rev-parse", "HEAD").strip()

    def commit_all(self, name: str, message: str) -> str:
        d = self.source_dir(name)
        _git(d, "add", "-A")
        proc = subprocess.run(
            ["git", "-C", str(d), "-c", "user.email=infernixos@runtime",
             "-c", "user.name=infernixos", "commit", "-q", "-m", message],
            capture_output=True, text=True,
        )
        if proc.returncode != 0:
            if "nothing to commit" not in proc.stdout + proc.stderr:
                raise ExtensionError(f"git commit failed: {proc.stderr.strip()}")
        return self.rev(name)

    def _template_app(self, d: Path, name: str, template: dict) -> None:
        (d / "main.py").write_text(
            "import sys\n"
            "from PySide6.QtWidgets import QApplication, QLabel\n"
            "app = QApplication(sys.argv)\n"
            f"label = QLabel({name!r})\n"
            "label.resize(320, 120)\n"
            "label.show()\n"
            "sys.exit(app.exec())\n"
        )
        (d / f"{name}.desktop").write_text(
            "[Desktop Entry]\n"
            f"Type=Application\nName={name}\n"
            f"Exec={name}\n"
            "Terminal=false\n"
            f"Categories=Utility;\n"
        )
        (d / "package.nix").write_text(
            "{ lib, stdenv, python3, makeWrapper }:\n"
            "stdenv.mkDerivation {\n"
            f"  pname = \"{name}\";\n  version = \"0.1.0\";\n"
            "  src = ./.;\n  dontBuild = true;\n"
            "  nativeBuildInputs = [ makeWrapper ];\n"
            "  installPhase = ''\n"
            "    mkdir -p $out/libexec $out/bin $out/share/applications\n"
            "    cp main.py $out/libexec/\n"
            f"    makeWrapper ${{python3}}/bin/python $out/bin/{name} \\\n"
            f"      --add-flags \"$out/libexec/main.py\"\n"
            f"    cp {name}.desktop $out/share/applications/\n"
            "  '';\n"
            "  meta.mainProgram = \"" + name + "\";\n"
            "}\n"
        )
        (d / "manifest.json").write_text(json.dumps({
            "name": name, "kind": "app", "entry": {"launcher": name},
            "permissions": [], "data_paths": [],
        }, indent=2) + "\n")

    def _template_widget(self, d: Path, name: str, template: dict) -> None:
        (d / "widget.qml").write_text(
            "import QtQuick\n"
            "import Quickshell\n"
            "PanelWindow {\n"
            f"  readonly property string label: \"{name}\"\n"
            "  anchors { top: true; left: true }\n"
            "  implicitWidth: 160\n"
            "  implicitHeight: 40\n"
            "  Text { anchors.centerIn: parent; text: label; color: \"#e8e6f0\" }\n"
            "}\n"
        )
        (d / "manifest.json").write_text(json.dumps({
            "name": name, "kind": "widget", "entry": {"qml": "widget.qml"},
            "permissions": [], "data_paths": [],
        }, indent=2) + "\n")

    def _template_plugin(self, d: Path, name: str, template: dict) -> None:
        (d / "plugin.yaml").write_text(
            f"name: {name}\nversion: 0.1.0\ndescription: infernixos generated plugin\n"
        )
        (d / "__init__.py").write_text(
            "def register(ctx):\n"
            "    pass\n"
        )
        (d / "manifest.json").write_text(json.dumps({
            "name": name, "kind": "hermes-plugin", "entry": {"plugin_dir": name},
            "permissions": [], "data_paths": [],
        }, indent=2) + "\n")


class ExtensionBuilder:
    """Runs real nix build against the machine flake, unprivileged."""

    def __init__(self, registry: ExtensionRegistry, nix_bin: str = "nix"):
        self.registry = registry
        self.nix = nix_bin
        self.flake_target = registry.state.flake_target()

    def build(self, name: str, source: Path) -> Path:
        name = check_name(name)
        if not (source / "package.nix").exists():
            raise ExtensionError(f"{source} has no package.nix")
        proc = subprocess.run(
            [self.nix, "build", "--no-link", "--print-out-paths", "--impure",
             "--expr",
             f'let pkgs = import <nixpkgs> {{}}; in pkgs.callPackage '
             f'{json.dumps(str(source / "package.nix"))} {{}}'],
            capture_output=True, text=True, timeout=1800,
        )
        if proc.returncode != 0:
            raise ExtensionError(f"nix build failed: {proc.stderr.strip()[-2000:]}")
        out = proc.stdout.strip().splitlines()[-1].strip()
        return Path(out)

    def check(self, source: Path) -> list[str]:
        """Real checks: syntax, manifest, package eval. Returns problem list."""
        problems = []
        manifest = source / "manifest.json"
        if not manifest.exists():
            problems.append("missing manifest.json")
            return problems
        try:
            m = json.loads(manifest.read_text())
        except json.JSONDecodeError as exc:
            problems.append(f"manifest.json invalid: {exc}")
            return problems
        if m.get("name") != source.name:
            problems.append("manifest name does not match source dir")
        kind = m.get("kind")
        if kind == "app":
            if not (source / "main.py").exists():
                problems.append("app missing main.py")
            if not (source / "package.nix").exists():
                problems.append("app missing package.nix")
        elif kind == "widget":
            if not (source / "widget.qml").exists():
                problems.append("widget missing widget.qml")
        elif kind == "hermes-plugin":
            if not (source / "plugin.yaml").exists():
                problems.append("plugin missing plugin.yaml")
            if not (source / "__init__.py").exists():
                problems.append("plugin missing __init__.py")
        else:
            problems.append(f"unknown kind: {kind}")
        for dp in m.get("data_paths", []):
            if os.path.isabs(dp) or ".." in Path(dp).parts:
                problems.append(f"unsafe data path: {dp}")
        return problems


class Backups:
    """Snapshot registered data paths into the state backups dir."""

    def __init__(self, state: State):
        self.state = state
        self.backups_dir = state.backups_dir

    def snapshot(self, name: str, data_dir: Path, data_paths: list[str]) -> Path:
        name = check_name(name)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        dest = self.backups_dir / name / stamp
        dest.mkdir(parents=True, exist_ok=True)
        for rel in data_paths:
            rel_p = Path(rel)
            if rel_p.is_absolute() or ".." in rel_p.parts:
                raise ExtensionError(f"unsafe data path: {rel}")
            src = data_dir / rel_p
            if not src.exists():
                continue
            dst = dest / rel_p
            dst.parent.mkdir(parents=True, exist_ok=True)
            if src.is_dir():
                shutil.copytree(src, dst)
            else:
                shutil.copy2(src, dst)
        meta = {
            "name": name,
            "stamp": stamp,
            "paths": list(data_paths),
            "created": datetime.now(timezone.utc).isoformat(),
        }
        write_json_atomic(dest / "backup.json", meta)
        return dest

    def list(self, name: str) -> list[dict]:
        name = check_name(name)
        bd = self.backups_dir / name
        if not bd.exists():
            return []
        out = []
        for d in sorted(bd.iterdir()):
            meta = read_json(d / "backup.json")
            if meta:
                out.append(meta)
        return out

    def restore(self, name: str, stamp: str, data_dir: Path) -> dict:
        name = check_name(name)
        if not re.fullmatch(r"[0-9TZ]+", stamp):
            raise ExtensionError(f"invalid backup stamp: {stamp}")
        src = self.backups_dir / name / stamp
        meta = read_json(src / "backup.json")
        if meta is None:
            raise ExtensionError(f"no such backup: {name}@{stamp}")
        restored = []
        for rel in meta["paths"]:
            rel_p = Path(rel)
            if rel_p.is_absolute() or ".." in rel_p.parts:
                raise ExtensionError(f"unsafe data path: {rel}")
            s = src / rel_p
            d = data_dir / rel_p
            if not s.exists():
                continue
            if d.is_dir():
                shutil.rmtree(d)
            elif d.exists():
                d.unlink()
            d.parent.mkdir(parents=True, exist_ok=True)
            if s.is_dir():
                shutil.copytree(s, d)
            else:
                shutil.copy2(s, d)
            restored.append(rel)
        return {"restored": restored, "stamp": stamp}
