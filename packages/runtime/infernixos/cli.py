"""infernixos runtime CLI.

Commands (machine-readable JSON on stdout, exit != 0 on failure):

  init --machine-source URL --flake-target TARGET --workspace DIR [--health-cmd CMD]...
  ownership                      Machine-readable source-ownership manifest.
  job create/run/status/cancel/list/resume
  ext create/build/check/install/update/remove/undo/list/disable/enable/set-entry/set-permissions/data-backup/data-restore
  activate request    Build a privileged activation candidate record.
  activate approve    Verify a candidate and emit the exact immutable
                      activation command for an authorized human to run.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from .state import State, StateError
from .jobs import JobStore, JobError
from .extensions import (
    ExtensionRegistry,
    ExtensionSource,
    ExtensionBuilder,
    Backups,
    ExtensionError,
)
from .activation import (
    ActivationStore,
    ActivationError,
    activation_command,
)
from .state import write_json_atomic


def _out(data) -> None:
    json.dump(data, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


def _fail(msg: str, code: int = 1) -> int:
    json.dump({"error": msg}, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return code


def _state() -> State:
    return State(Path(os.environ.get("INFERNIXOS_STATE") or Path.home() / ".local" / "state" / "infernixos"))


def cmd_init(args) -> int:
    try:
        m = _state().init(
            machine_source=args.machine_source,
            flake_target=args.flake_target,
            extension_workspace=args.workspace,
            health_commands=args.health_cmd,
            force=args.force,
        )
    except StateError as exc:
        return _fail(str(exc))
    _out(m)
    return 0


def cmd_ownership(args) -> int:
    st = _state()
    try:
        m = st.manifest()
    except StateError as exc:
        return _fail(str(exc))
    _out({
        "version": m["version"],
        "runtime": m.get("runtime", "infernixos"),
        "machine_source": m["machine_source"],
        "flake_target": m["flake_target"],
        "extension_workspace": m["extension_workspace"],
        "health_commands": m.get("health_commands", []),
        "state_root": str(st.root),
        "commands": {
            "job": "infernixos job",
            "extension": "infernixos ext",
            "activation": "infernixos activate",
        },
    })
    return 0


def cmd_job(args) -> int:
    store = JobStore(_state())
    try:
        if args.job_cmd == "create":
            phases = [{"name": n, "prompt": p} for n, p in args.phase]
            rec = store.create(args.name, args.request_id, phases)
            return _ok({"job_id": rec["job_id"], "status": rec["status"]})
        if args.job_cmd == "run" or args.job_cmd == "resume":
            rec = store.run(args.job_id)
            return _ok(store.status(args.job_id))
        if args.job_cmd == "status":
            return _ok(store.status(args.job_id))
        if args.job_cmd == "cancel":
            store.cancel(args.job_id)
            return _ok(store.status(args.job_id))
        if args.job_cmd == "list":
            return _ok({"jobs": store.list_jobs()})
    except JobError as exc:
        return _fail(str(exc))
    return _fail("unknown job subcommand")


def _ok(data) -> int:
    _out(data)
    return 0


def cmd_ext(args) -> int:
    st = _state()
    reg = ExtensionRegistry(st)
    src = ExtensionSource(reg)
    try:
        if args.ext_cmd == "create":
            d = src.create(args.name, args.kind, {})
            return _ok({"name": args.name, "source": str(d), "kind": args.kind})
        if args.ext_cmd == "build":
            out = ExtensionBuilder(reg).build(args.name, src.source_dir(args.name))
            return _ok({"name": args.name, "out": str(out)})
        if args.ext_cmd == "check":
            problems = ExtensionBuilder(reg).check(src.source_dir(args.name))
            return _ok({"name": args.name, "ok": not problems, "problems": problems})
        if args.ext_cmd == "install":
            d = src.source_dir(args.name)
            builder = ExtensionBuilder(reg)
            problems = builder.check(d)
            if problems:
                return _fail(f"checks failed: {problems}")
            rev = src.rev(args.name)
            out = builder.build(args.name, d)
            manifest = json.loads((d / "manifest.json").read_text())
            ext = reg.record(
                args.name, str(d), rev, str(out), None,
                manifest.get("entry"), args.request_id, args.session_id,
                manifest.get("permissions"),
            )
            _install_artifacts(st, ext, d)
            return _ok({"name": args.name, "out": str(out), "rev": rev})
        if args.ext_cmd == "update":
            d = src.source_dir(args.name)
            rev = src.commit_all(args.name, args.message or f"update {args.name}")
            builder = ExtensionBuilder(reg)
            problems = builder.check(d)
            if problems:
                return _fail(f"checks failed: {problems}")
            out = builder.build(args.name, d)
            manifest = json.loads((d / "manifest.json").read_text())
            prev = reg.get(args.name)
            ext = reg.record(
                args.name, str(d), rev, str(out), None,
                manifest.get("entry"), prev.get("request_id"), prev.get("session_id"),
                manifest.get("permissions"),
            )
            _install_artifacts(st, ext, d)
            return _ok({"name": args.name, "out": str(out), "rev": rev})
        if args.ext_cmd == "remove":
            _backup_before_remove(st, reg, args.name)
            ext = reg.get(args.name)
            reg.forget(args.name)
            _remove_artifacts(ext)
            return _ok({"name": args.name, "removed": True, "data_preserved": True})
        if args.ext_cmd == "undo":
            ext = reg.get(args.name)
            prev = reg.last_accepted(args.name, ext["updated"])
            if prev is None:
                return _fail("no previous accepted package to undo to")
            ext2 = reg.record(
                args.name, prev["source"]["path"], prev["source"]["rev"],
                prev["package"]["out"], None, prev.get("entry"),
                ext.get("request_id"), ext.get("session_id"),
                ext.get("permissions"),
            )
            _install_artifacts(st, ext2, src.source_dir(args.name))
            return _ok({"name": args.name, "out": prev["package"]["out"], "undone": True})
        if args.ext_cmd == "list":
            return _ok({"extensions": reg.all()})
        if args.ext_cmd == "disable":
            return _ok(reg.set_disabled(args.name, True))
        if args.ext_cmd == "enable":
            return _ok(reg.set_disabled(args.name, False))
        if args.ext_cmd == "set-entry":
            return _ok(reg.set_entry(args.name, json.loads(args.entry)))
        if args.ext_cmd == "set-permissions":
            return _ok(reg.set_permissions(args.name, args.permission))
        if args.ext_cmd == "data-backup":
            ext = reg.get(args.name)
            data_dir = Path(ext["data_dir"])
            b = Backups(st).snapshot(args.name, data_dir, json.loads(args.paths) if args.paths else [])
            return _ok({"name": args.name, "backup": str(b)})
        if args.ext_cmd == "data-restore":
            ext = reg.get(args.name)
            r = Backups(st).restore(args.name, args.stamp, Path(ext["data_dir"]))
            return _ok(r)
    except (ExtensionError, StateError) as exc:
        return _fail(str(exc))
    return _fail("unknown ext subcommand")


def _backup_before_remove(st, reg, name) -> None:
    try:
        ext = reg.get(name)
        data_dir = Path(ext["data_dir"])
        if data_dir.exists() and any(data_dir.iterdir()):
            manifest_src = src_manifest_data_paths(ext)
            Backups(st).snapshot(name, data_dir, manifest_src)
    except ExtensionError:
        pass


def src_manifest_data_paths(ext: dict) -> list[str]:
    src = Path(ext["source"]["path"]) / "manifest.json"
    try:
        return json.loads(src.read_text()).get("data_paths", [])
    except (OSError, json.JSONDecodeError):
        return []


def _install_artifacts(st, ext: dict, source_dir: Path) -> None:
    kind = ext["entry"].get("kind_hint") or _kind_of(source_dir)
    d = st.extension_dir(ext["name"])
    d.mkdir(parents=True, exist_ok=True)
    write_json_atomic(d / "install.json", {
        "name": ext["name"],
        "package_out": ext["package"]["out"],
        "source_rev": ext["source"]["rev"],
        "kind": kind,
        "entry": ext["entry"],
    })
    if kind == "hermes-plugin":
        link = d / "plugin"
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(source_dir)


def _kind_of(source_dir: Path) -> str:
    try:
        return json.loads((source_dir / "manifest.json").read_text()).get("kind", "app")
    except (OSError, json.JSONDecodeError):
        return "app"


def _remove_artifacts(ext: dict) -> None:
    import shutil
    st = _state()
    d = st.extension_dir(ext["name"])
    install = d / "install.json"
    if install.exists():
        install.unlink()
    plugin = d / "plugin"
    if plugin.is_symlink():
        plugin.unlink()


def cmd_activate(args) -> int:
    st = _state()
    try:
        store = ActivationStore(st)
        if args.activate_cmd == "request":
            rec = store.create_request(args.label, args.closure, args.expected_base)
            _out({"candidate_id": rec["candidate_id"], "status": rec["status"],
                  "record": str(store.record_path(rec["candidate_id"]))})
            return 0
        if args.activate_cmd == "approve":
            rec = store.verify_and_prepare(args.candidate_id, args.closure, args.expected_base)
            cmd = activation_command(rec)
            _out({"candidate_id": rec["candidate_id"], "status": rec["status"],
                  "activation_command": cmd,
                  "note": "run the printed command yourself; it requires root authorization"})
            return 0
        if args.activate_cmd == "status":
            return _ok(store.load(args.candidate_id))
        if args.activate_cmd == "list":
            return _ok({"candidates": store.list_candidates()})
    except ActivationError as exc:
        return _fail(str(exc))
    return _fail("unknown activate subcommand")


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="infernixos")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("init")
    sp.add_argument("--machine-source", required=True)
    sp.add_argument("--flake-target", required=True)
    sp.add_argument("--workspace", required=True)
    sp.add_argument("--health-cmd", action="append", default=[])
    sp.add_argument("--force", action="store_true")
    sp.set_defaults(func=cmd_init)

    sp = sub.add_parser("ownership")
    sp.set_defaults(func=cmd_ownership)

    sp = sub.add_parser("job")
    jsub = sp.add_subparsers(dest="job_cmd", required=True)
    for name, extra in (
        ("create", [("name",), ("request_id",), ("--phase", 2)]),
    ):
        pass
    jc = jsub.add_parser("create")
    jc.add_argument("--name", required=True)
    jc.add_argument("--request-id", required=True)
    jc.add_argument("--phase", action="append", nargs=2, metavar=("NAME", "PROMPT"), default=[])
    jc.set_defaults(func=cmd_job)
    for name in ("run", "resume", "status", "cancel"):
        js = jsub.add_parser(name)
        js.add_argument("job_id")
        js.set_defaults(func=cmd_job)
    jsub.add_parser("list").set_defaults(func=cmd_job)

    sp = sub.add_parser("ext")
    esub = sp.add_subparsers(dest="ext_cmd", required=True)
    ec = esub.add_parser("create")
    ec.add_argument("name")
    ec.add_argument("kind", choices=["app", "widget", "hermes-plugin"])
    ec.set_defaults(func=cmd_ext)
    for name in ("build", "check", "remove", "undo", "list", "disable", "enable"):
        es = esub.add_parser(name)
        if name != "list":
            es.add_argument("name")
        es.set_defaults(func=cmd_ext)
    eu = esub.add_parser("update")
    eu.add_argument("name")
    eu.add_argument("--message", default=None)
    eu.set_defaults(func=cmd_ext)
    ei = esub.add_parser("install")
    ei.add_argument("name")
    ei.add_argument("--request-id", default=None)
    ei.add_argument("--session-id", default=None)
    ei.set_defaults(func=cmd_ext)
    es = esub.add_parser("set-entry")
    es.add_argument("name")
    es.add_argument("entry")
    es.set_defaults(func=cmd_ext)
    esp = esub.add_parser("set-permissions")
    esp.add_argument("name")
    esp.add_argument("--permission", action="append", default=[])
    esp.set_defaults(func=cmd_ext)
    eb = esub.add_parser("data-backup")
    eb.add_argument("name")
    eb.add_argument("--paths", default="[]")
    eb.set_defaults(func=cmd_ext)
    er = esub.add_parser("data-restore")
    er.add_argument("name")
    er.add_argument("stamp")
    er.set_defaults(func=cmd_ext)

    sp = sub.add_parser("activate")
    asub = sp.add_subparsers(dest="activate_cmd", required=True)
    ar = asub.add_parser("request")
    ar.add_argument("--label", required=True)
    ar.add_argument("--closure", required=True)
    ar.add_argument("--expected-base", required=True)
    ar.set_defaults(func=cmd_activate)
    aa = asub.add_parser("approve")
    aa.add_argument("candidate_id")
    aa.add_argument("--closure", required=True)
    aa.add_argument("--expected-base", required=True)
    aa.set_defaults(func=cmd_activate)
    ast = asub.add_parser("status")
    ast.add_argument("candidate_id")
    ast.set_defaults(func=cmd_activate)
    asub.add_parser("list").set_defaults(func=cmd_activate)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
