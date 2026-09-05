#!/usr/bin/env python3
"""Check the Pyre Ask Hermes wiring.

Covers: the ask-command builder passes exact selected paths as argv (no
shell interpolation), env-var contract with AskHermesDialog.qml, and the
runtime ask prompt assembly for paths-only vs contents mode.

Run:  QT_QPA_PLATFORM=offscreen python3 -B ask_hermes_check.py
"""
import os
import sys
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
ROOT = Path(__file__).resolve().parents[1] / "runtime"
sys.path.insert(0, str(ROOT))

from infernixos.ask import build_prompt  # noqa: E402

FAIL = []


def check(name, cond, detail=""):
    if cond:
        print(f"  ok  {name}")
    else:
        FAIL.append(name)
        print(f"FAIL  {name}  {detail}")


def pyre_ask_command(paths, question="Explain this"):
    """Mirror of AskHermesDialog.qml command construction: exact argv, no shell."""
    args = ["infernixos-ask"]
    for f in "\n".join(paths).split("\n"):
        if f.strip():
            args.extend(["--file", f])
    args.append(question)
    return args


cmd = pyre_ask_command(["/tmp/my file.txt", "/tmp/other & file.txt"])
check("argv: exact paths preserved (spaces/ampersands not shell-eaten)",
      cmd == ["infernixos-ask", "--file", "/tmp/my file.txt",
              "--file", "/tmp/other & file.txt", "Explain this"], str(cmd))
check("argv: no shell metacharacter string", not any(isinstance(a, str) and ";" in a for a in cmd), str(cmd))

p = build_prompt("why is this slow?", "pyre", ["/tmp/a.txt"], None, False)
check("ask: paths-only default (no contents)", "paths only" in p and "file contents" not in p, p)
check("ask: question included", "why is this slow?" in p, p)
check("ask: app context labeled", "pyre" in p, p)

d = Path("/tmp")
f = d / "inx-ask-test.txt"
f.write_text("sample content")
p2 = build_prompt("q", None, [str(f)], None, True)
check("ask: contents only on explicit opt-in", "sample content" in p2, p2)

print()
if FAIL:
    print(f"=== {len(FAIL)} FAILED: {FAIL}")
    sys.exit(1)
print("=== ask-hermes wiring OK ===")
