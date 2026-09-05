"""TerminalSession — minimal embedded shell for the Terminal panel.

QProcess-backed bash (merged stdout/stderr). Not a real PTY: no colors/job
control — the "Open in kitty" button is the escape hatch for that.
"""
from __future__ import annotations

import shlex
from pathlib import Path

from PySide6.QtCore import QObject, QProcess, Signal, Slot


class TerminalSession(QObject):
    output = Signal(str)

    def __init__(self):
        super().__init__()
        self._proc: QProcess | None = None

    @Slot()
    def start(self):
        if self._proc is not None:
            return
        self._proc = QProcess(self)
        self._proc.setWorkingDirectory(str(Path.home()))
        self._proc.setProgram("bash")
        self._proc.setArguments(["--noprofile", "--norc", "-i"])
        self._proc.setProcessChannelMode(QProcess.ProcessChannelMode.MergedChannels)
        self._proc.readyReadStandardOutput.connect(self._read)
        self._proc.start()

    def _read(self):
        if self._proc is None:
            return
        data = bytes(self._proc.readAllStandardOutput()).decode("utf-8", "replace")
        if data:
            self.output.emit(data)

    @Slot(str)
    def writeInput(self, s: str):
        if self._proc is not None:
            self._proc.write(s.encode("utf-8"))

    @Slot(str)
    def cd(self, path: str):
        self.writeInput(f"cd {shlex.quote(path)}\n")


if __name__ == "__main__":
    print("PASS TerminalSession import (needs a Qt event loop to run)")
