"""SearchModel — recursive filename/content search results (PRD §9).

Simple search (Ctrl+F) matches filenames by substring, recursively.
Advanced search adds content grep, size range, date-modified range, file-type
filter, and a recursive vs current-folder-only scope. All criteria combine
(AND). Both run in a worker QThread so the UI never blocks.
"""
from __future__ import annotations

import os
from datetime import datetime
from pathlib import Path

from PySide6.QtCore import Property, QAbstractListModel, QModelIndex, Qt, QThread, Signal, Slot

# Read this much of a file to decide text-vs-binary before content-grep.
_BINARY_PROBE = 8192


def _parse_date(v) -> float | None:
    """Accept an epoch number or a 'YYYY-MM-DD[ HH:MM]' string; None if empty."""
    if v is None or v == "":
        return None
    if isinstance(v, (int, float)):
        return float(v)
    s = str(v).strip()
    if not s:
        return None
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
        try:
            return datetime.strptime(s, fmt).timestamp()
        except ValueError:
            continue
    return None


def _is_text(path: str) -> bool:
    """Binary detection: a NUL byte in the first chunk marks the file binary."""
    try:
        with open(path, "rb") as fh:
            chunk = fh.read(_BINARY_PROBE)
    except OSError:
        return False
    return b"\x00" not in chunk


class _Searcher(QThread):
    found = Signal(str)  # a matched file path
    finishedSearch = Signal(int)  # total count

    def __init__(self, root: Path, term: str = "", opts: dict | None = None):
        super().__init__()
        self._root = root
        o = opts or {}
        self._name = (o.get("name") or term or "").lower()
        self._content = (o.get("content") or "").lower()
        # 0 / empty means "no bound"; a zero min/max is meaningless as a filter.
        self._size_min = o.get("sizeMin") or None
        self._size_max = o.get("sizeMax") or None
        self._from_ts = _parse_date(o.get("from"))
        self._to_ts = _parse_date(o.get("to"))
        self._ftype = (o.get("type") or "").lower().lstrip(".")
        self._recursive = bool(o.get("recursive", True))
        self._count = 0

    def run(self):
        if self._recursive:
            for dirpath, dirnames, filenames in os.walk(self._root):
                dirnames[:] = [d for d in dirnames if not d.startswith(".")]
                for f in filenames:
                    if f.startswith("."):
                        continue
                    full = os.path.join(dirpath, f)
                    if self._matches(full, f):
                        self._count += 1
                        self.found.emit(full)
        else:
            # current folder only — no descent into subdirectories
            try:
                with os.scandir(self._root) as it:
                    for e in it:
                        if e.name.startswith("."):
                            continue
                        try:
                            if e.is_file() and self._matches(e.path, e.name):
                                self._count += 1
                                self.found.emit(e.path)
                        except OSError:
                            continue
            except OSError:
                pass
        self.finishedSearch.emit(self._count)

    def _matches(self, path: str, name: str) -> bool:
        if self._name and self._name not in name.lower():
            return False
        if self._ftype and not name.lower().endswith("." + self._ftype):
            return False
        try:
            st = os.stat(path)
        except OSError:
            return False
        if self._size_min is not None and st.st_size < self._size_min:
            return False
        if self._size_max is not None and st.st_size > self._size_max:
            return False
        mt = st.st_mtime
        if self._from_ts is not None and mt < self._from_ts:
            return False
        if self._to_ts is not None and mt > self._to_ts:
            return False
        if self._content:
            if not _is_text(path):
                return False
            try:
                with open(path, "rb") as fh:
                    data = fh.read()
            except OSError:
                return False
            if self._content.encode() not in data.lower():
                return False
        return True


class SearchModel(QAbstractListModel):
    R_PATH = Qt.UserRole + 1

    searchingChanged = Signal()

    def __init__(self):
        super().__init__()
        self._results: list[str] = []
        self._thread: _Searcher | None = None
        self._searching = False

    @property
    def searching(self) -> bool:
        return self._searching

    def _get_results(self) -> int:
        return len(self._results)

    results = property(_get_results)
    resultsProp = Property(int, _get_results, notify=searchingChanged)

    def rowCount(self, parent: QModelIndex = QModelIndex()) -> int:
        return 0 if parent.isValid() else len(self._results)

    def data(self, index: QModelIndex, role: int = Qt.DisplayRole):
        if not index.isValid() or not (0 <= index.row() < len(self._results)):
            return None
        if role == Qt.DisplayRole or role == self.R_PATH:
            return self._results[index.row()]
        return None

    def roleNames(self):
        return {self.R_PATH: b"path"}

    @Slot(str, str)
    def search(self, root: str, term: str):
        """Simple recursive filename-substring search (Ctrl+F)."""
        self._search(Path(root), term)

    @Slot(str, "QVariantMap")
    def advancedSearch(self, root: str, opts: dict):
        """Advanced search with an opts dict (content/size/date/type/scope)."""
        self._search(Path(root), "", dict(opts))

    @Slot(result="QString")
    def firstResult(self) -> str:
        """Path of the first result (for Enter-opens-first in the dialog)."""
        return self._results[0] if self._results else ""

    def _search(self, root: Path, term: str, opts: dict | None = None):
        if self._thread and self._thread.isRunning():
            return
        self.beginResetModel()
        self._results.clear()
        self.endResetModel()
        if not term and not opts:
            return
        self._searching = True
        self.searchingChanged.emit()
        self._thread = _Searcher(root, term, opts)
        self._thread.found.connect(self._add)
        self._thread.finishedSearch.connect(self._done)
        self._thread.start()

    def _add(self, path: str):
        self.beginInsertRows(QModelIndex(), len(self._results), len(self._results))
        self._results.append(path)
        self.endInsertRows()

    def _done(self, count: int):
        self._searching = False
        self.searchingChanged.emit()
        self._thread = None


if __name__ == "__main__":
    import tempfile
    from PySide6.QtCore import QCoreApplication
    app = QCoreApplication.instance() or QCoreApplication([])
    m = SearchModel()
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        (root / "report.txt").write_text("needle in haystack")
        (root / "sub").mkdir()
        (root / "sub" / "report2.txt").write_text("plain")
        m._search(root, "report")
        if m._thread:
            m._thread.wait()
            app.processEvents()
        paths = [m.data(m.index(i), m.R_PATH) for i in range(m.rowCount())]
        assert len(paths) == 2, f"got {paths}"
    print(f"PASS SearchModel: found {len(paths)}")
