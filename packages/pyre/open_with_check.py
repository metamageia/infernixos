#!/usr/bin/env python3
"""Check for the freedesktop open-with logic in core.py.

Covers: .desktop parsing, MimeType matching (incl. globs), Exec field-code
expansion, apps-for-mime discovery, and mimeapps.list default persistence.
Pure Python — no Qt required (fs_model import needs PySide6 though).

Run:  nix-shell -p "python3.withPackages (ps: [ ps.pyside6 ])" --run \
        "QT_QPA_PLATFORM=offscreen python3 open_with_check.py"
"""
import os
import shlex
import sys
import tempfile
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, str(Path(__file__).parent))
import core  # noqa: E402

FAIL = []


def check(name, cond, detail=""):
    if cond:
        print(f"  ok  {name}")
    else:
        FAIL.append(name)
        print(f"FAIL  {name}  {detail}")


# ---- Exec field-code expansion ----
cmd = core._exec_cmd(
    {"Exec": "kate %f --line 10", "Name": "Kate", "Icon": "kate"},
    Path("/usr/share/applications/kate.desktop"),
    Path("/tmp/my file.txt"),
)
check("exec: %f replaced (quoted)", cmd == ["kate", "/tmp/my file.txt", "--line", "10"], str(cmd))

cmd = core._exec_cmd(
    {"Exec": "firefox %u", "Name": "Firefox", "Icon": "firefox"},
    Path("/usr/share/applications/firefox.desktop"),
    Path("/tmp/page.html"),
)
check("exec: %u → file URI", cmd == ["firefox", "file:///tmp/page.html"], str(cmd))

cmd = core._exec_cmd(
    {"Exec": "mpv --force-window", "Name": "MPV"},
    Path("/usr/share/applications/mpv.desktop"),
    Path("/tmp/vid.mkv"),
)
check("exec: no file code → path appended", cmd == ["mpv", "--force-window", "/tmp/vid.mkv"], str(cmd))

cmd = core._exec_cmd(
    {"Exec": "env FOO=bar app %i %c", "Name": "Weird App", "Icon": "w"},
    Path("/usr/share/applications/w.desktop"),
    Path("/tmp/f"),
)
check("exec: %i/%c expanded, env kept",
      cmd == ["env", "FOO=bar", "app", "--icon", "w", "Weird App", "/tmp/f"], str(cmd))

# ---- MimeType matching ----
check("mime: exact", core._mime_matches("text/plain;text/html", "text/plain"))
check("mime: glob", core._mime_matches("text/*;application/json", "text/x-python"))
check("mime: non-match", not core._mime_matches("text/*", "image/png"))
check("mime: empty", not core._mime_matches("", "text/plain"))

# ---- .desktop parsing ----
with tempfile.TemporaryDirectory() as td:
    d = Path(td)
    (d / "applications").mkdir()
    (d / "applications" / "foo.desktop").write_text(
        "[Desktop Entry]\n"
        "Type=Application\n"
        "Name=Foo Viewer\n"
        "Icon=foo-icon\n"
        "Exec=foo %f\n"
        "MimeType=text/plain;image/*;\n"
    )
    (d / "applications" / "hidden.desktop").write_text(
        "[Desktop Entry]\n"
        "Type=Application\n"
        "Name=Hidden App\n"
        "Exec=hidden %f\n"
        "MimeType=text/plain;\n"
        "NoDisplay=true\n"  # kept: NoDisplay entries are valid open-with handlers (okular mime aliases)
    )
    (d / "applications" / "buried.desktop").write_text(
        "[Desktop Entry]\n"
        "Type=Application\n"
        "Name=Buried App\n"
        "Exec=buried %f\n"
        "MimeType=text/plain;\n"
        "Hidden=true\n"  # filtered: Hidden means deleted/uninstalled
    )
    (d / "applications" / "bar.desktop").write_text(
        "[Desktop Entry]\n"
        "Type=Application\n"
        "Name=Bar Editor\n"
        "Exec=bar\n"
        "MimeType=application/octet-stream;\n"
    )
    e = core._parse_desktop(d / "applications" / "foo.desktop")
    check("desktop: parse keys", e.get("Name") == "Foo Viewer" and e.get("MimeType", "").startswith("text/plain"), str(e))

    # discovery honors XDG_DATA_DIRS
    old = os.environ.get("XDG_DATA_DIRS")
    os.environ["XDG_DATA_DIRS"] = str(d)
    try:
        apps = core._apps_for_mime("text/plain")
        ids = [a["id"] for a in apps]
        check("apps: finds foo + hidden (NoDisplay is a valid handler), excludes bar (mime) + buried (Hidden)",
              "foo.desktop" in ids and "hidden.desktop" in ids
              and "bar.desktop" not in ids and "buried.desktop" not in ids, str(ids))
        foo = next(a for a in apps if a["id"] == "foo.desktop")
        check("apps: name+icon surfaced", foo["name"] == "Foo Viewer" and foo["icon"] == "foo-icon", str(foo))
        check("apps: glob match finds foo for image/png",
              any(a["id"] == "foo.desktop" for a in core._apps_for_mime("image/png")))
    finally:
        if old is None:
            os.environ.pop("XDG_DATA_DIRS", None)
        else:
            os.environ["XDG_DATA_DIRS"] = old

    # ---- mimeapps.list persistence (fallback path: force xdg-mime failure) ----
    fake_home = d / "home"
    fake_home.mkdir()
    old_home = os.environ.get("HOME")
    os.environ["HOME"] = str(fake_home)
    try:
        real_run = core.subprocess.run
        core.subprocess.run = lambda *a, **k: (_ for _ in ()).throw(
            FileNotFoundError("no xdg-mime")
        )
        try:
            core._set_default("text/plain", "foo.desktop")
        finally:
            core.subprocess.run = real_run
        lines = (fake_home / ".config" / "mimeapps.list").read_text().splitlines()
        check("default: writes mimeapps.list",
              "[Default Applications]" in lines and "text/plain=foo.desktop" in lines, str(lines))
        # idempotent replace
        core.subprocess.run = lambda *a, **k: (_ for _ in ()).throw(
            FileNotFoundError("no xdg-mime")
        )
        try:
            core._set_default("text/plain", "bar.desktop")
        finally:
            core.subprocess.run = real_run
        lines = (fake_home / ".config" / "mimeapps.list").read_text().splitlines()
        check("default: replaces existing mapping",
              lines.count("text/plain=bar.desktop") == 1 and "text/plain=foo.desktop" not in lines, str(lines))
    finally:
        os.environ.pop("HOME", None)
        if old_home is not None:
            os.environ["HOME"] = old_home

print()
if FAIL:
    print(f"=== {len(FAIL)} FAILED: {FAIL}")
    sys.exit(1)
print("=== open-with logic OK ===")
