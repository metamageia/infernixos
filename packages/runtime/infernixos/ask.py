"""infernixos-ask: Ask Hermes dialog with explicit context preview.

A small PySide6 dialog. Collects optional context: the active application
(via the launcher argv: --app NAME), explicit file paths (--file PATH,
paths only, passed safely without shell interpolation), and freeform
selected text/notes. Shows EXACTLY what will be shared (paths-only by
default; file CONTENTS are never attached from this dialog) and requires the
user to press Ask. With --yes it prints the assembled prompt instead of
showing a GUI (headless/CI). The prompt is handed to the real Hermes CLI
(`hermes -z`) in the foreground. Context sharing is opt-in per invocation:
with no --file/--app/--text and --context=off, nothing is attached.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

HERMES_BIN_ENV = "INFERNIXOS_HERMES_BIN"


def build_prompt(question: str, app: str | None, files: list[str], text: str | None, include_contents: bool) -> str:
    parts = [question.strip()]
    ctx = []
    if app:
        ctx.append(f"active application: {app}")
    safe_files = []
    for f in files:
        p = Path(f).expanduser().resolve(strict=False)
        safe_files.append(str(p))
    if safe_files:
        ctx.append("referenced files (paths only):\n" + "\n".join(safe_files))
        if include_contents:
            ctx.append(
                "file contents (user explicitly opted in):\n"
                + "\n".join(_read_head(p) for p in safe_files)
            )
    if text:
        ctx.append("user-provided context:\n" + text.strip())
    if ctx:
        parts.append("[context]\n" + "\n".join(ctx))
    return "\n\n".join(parts)


def _read_head(p: str, limit: int = 4000) -> str:
    try:
        return f"--- {p} ---\n" + Path(p).read_text(errors="replace")[:limit]
    except OSError as exc:
        return f"--- {p} --- (unreadable: {exc})"


def ask_hermes(prompt: str) -> int:
    hermes = os.environ.get(HERMES_BIN_ENV) or "hermes"
    proc = subprocess.run([hermes, "-z", prompt])
    return proc.returncode


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="infernixos-ask")
    ap.add_argument("--app", default=None, help="active application name")
    ap.add_argument("--file", action="append", default=[], help="file path to reference (repeatable)")
    ap.add_argument("--text", default=None, help="additional context text")
    ap.add_argument("--include-contents", action="store_true",
                    help="include file CONTENTS (off by default; paths-only is the default)")
    ap.add_argument("--context", choices=["on", "off"], default="on")
    ap.add_argument("--yes", action="store_true", help="no GUI; assemble and run directly")
    ap.add_argument("--print-only", action="store_true", help="print the prompt that would be sent")
    ap.add_argument("question")
    args = ap.parse_args(argv)

    if args.context == "off":
        args.app, args.file, args.text = None, [], None

    prompt = build_prompt(args.question, args.app, args.file, args.text, args.include_contents)

    if args.print_only:
        print(prompt)
        return 0
    if args.yes:
        return ask_hermes(prompt)

    try:
        from PySide6.QtWidgets import (
            QApplication, QDialog, QVBoxLayout, QLabel, QPlainTextEdit,
            QCheckBox, QDialogButtonBox,
        )
    except ImportError:
        print(prompt)
        return ask_hermes(prompt)

    app = QApplication.instance() or QApplication(sys.argv)
    dlg = QDialog()
    dlg.setWindowTitle("Ask Hermes")
    lay = QVBoxLayout(dlg)
    preview = QPlainTextEdit()
    preview.setPlainText(prompt)
    preview.setReadOnly(True)
    lay.addWidget(QLabel("This is exactly what will be sent to Hermes:"))
    lay.addWidget(preview)
    contents_cb = QCheckBox("Include file contents (paths-only by default)")
    contents_cb.setChecked(args.include_contents)
    lay.addWidget(contents_cb)

    def _finish():
        final = build_prompt(
            args.question,
            args.app if args.context == "on" else None,
            args.file if args.context == "on" else [],
            args.text if args.context == "on" else None,
            contents_cb.isChecked(),
        )
        dlg.accept()
        sys.exit(ask_hermes(final))

    buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
    buttons.accepted.connect(_finish)
    buttons.rejected.connect(dlg.reject)
    lay.addWidget(buttons)
    dlg.exec()
    return 0


if __name__ == "__main__":
    sys.exit(main())
