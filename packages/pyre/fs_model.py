"""FileSystemModel — QAbstractListModel exposing one directory.

Columns per PRD §5: name, size, modified, type, permissions, owner, group.
Supports natural-number-aware sorting (file2 < file10), dirs-first toggle,
selection state, per-view zoom (icon size), and a status line.
"""
from __future__ import annotations

import enum
import grp
import hashlib
import locale
import os
import pwd
import re
import stat as statmod
from datetime import datetime
from pathlib import Path

from PySide6.QtCore import Property, QAbstractListModel, QFileSystemWatcher, QModelIndex, QTimer, Qt, Signal, Slot

# Natural number collation: split runs of digits, zero-pad for length-aware order
_DIGITS = re.compile(r"(\d+)")

_IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".svg", ".ico"}
_VIDEO_EXTS = {".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v", ".flv", ".wmv", ".ogv", ".mpeg", ".mpg"}
_PDF_EXTS = {".pdf"}
NATURAL_CACHE: dict[str, tuple] = {}


def _thumb_cache_dir() -> Path:
    """Writable poster cache (NOT the nix store). Follows the real $HOME."""
    return Path.home() / ".cache" / "pyre" / "thumbs"


def thumb_path_for(p: Path) -> Path:
    """Deterministic cache path for a file's poster thumbnail (md5 of abs path)."""
    h = hashlib.md5(str(p.resolve()).encode("utf-8")).hexdigest()
    return _thumb_cache_dir() / f"{h}.png"


def thumbnailable(p: Path) -> bool:
    """True for video/PDF files that can get a generated poster thumbnail."""
    if not p.is_file():
        return False
    return p.suffix.lower() in _VIDEO_EXTS or p.suffix.lower() in _PDF_EXTS


def _natkey(s: str) -> tuple:
    try:
        return NATURAL_CACHE[s]
    except KeyError:
        parts = _DIGITS.split(s.lower())
        key = tuple(int(d) if d.isdigit() else d for d in parts)
        NATURAL_CACHE[s] = key
        return key


class SortKey(enum.IntEnum):
    NAME = 0
    SIZE = 1
    MODIFIED = 2
    TYPE = 3


class FileSystemModel(QAbstractListModel):
    """Flat single-directory listing."""

    R_NAME = Qt.UserRole + 1
    R_PATH = Qt.UserRole + 2
    R_ISDIR = Qt.UserRole + 3
    R_SIZE = Qt.UserRole + 4
    R_MODIFIED = Qt.UserRole + 5
    R_TYPE = Qt.UserRole + 6
    R_PERMS = Qt.UserRole + 7
    R_OWNER = Qt.UserRole + 8
    R_GROUP = Qt.UserRole + 9
    R_SELECTED = Qt.UserRole + 10
    R_EXT = Qt.UserRole + 11  # extension without dot, lowercased ("" for none)
    R_SIZETXT = Qt.UserRole + 12  # human size string
    R_MODTXT = Qt.UserRole + 13  # formatted modified
    R_ICON = Qt.UserRole + 14  # icon name hint for QML
    R_THUMB = Qt.UserRole + 15  # file:// URL for image thumbnails ("" if none)
    R_GROUPKEY = Qt.UserRole + 16  # section header label for the grouped details view

    currentChanged = Signal()
    filterChanged = Signal()
    groupChanged = Signal()
    hiddenChanged = Signal()

    def __init__(self, root: Path):
        super().__init__()
        self._root = root
        self._entries: list[Path] = []
        self._all_entries: list[Path] = []
        # Stat cache: one os.stat_result per entry per listing, cleared on
        # reload. pathlib doesn't cache stat(), so without this the sort key
        # (e.stat() + e.is_dir()) and every per-role data() lookup fire a
        # fresh syscall on the UI thread — the "lag before opening a folder".
        # ponytail: metadata is a per-listing snapshot, not live — a file's
        # size/mtime shows stale until the next reload/navigation. That is the
        # deliberate trade for a single stat per entry instead of per-role.
        self._stat_cache: dict[str, os.stat_result] = {}
        self._selected: set[int] = set()
        self._anchor: int | None = None  # selection anchor for Shift+click range
        self._current: int = -1  # keyboard-nav current row (for arrows/type-ahead)
        self.sort_key = SortKey.NAME
        self.sort_desc = False
        self.dirs_first = True
        self.show_hidden = False
        self.icon_size = 32
        self._filter_text = ""
        self._group_mode = "letter"  # letter | type | date
        # inotify auto-refresh: watch the current dir; on change reload once
        # (debounced — a cp into the folder fires many events).
        self._watcher = QFileSystemWatcher(self)
        self._watcher.directoryChanged.connect(self._on_dir_changed)
        self._reload_timer: QTimer | None = None
        self.reload()

    @property
    def root(self) -> Path:
        return self._root

    def _get_root(self) -> str:
        return str(self._root)

    rootProp = Property(str, _get_root)

    @property
    def statusText(self) -> str:
        n = len(self._entries)
        sel = len(self._selected)
        s = f"{n} item{'s' if n != 1 else ''}, {sel} selected"
        return s

    def _stat(self, p: Path) -> os.stat_result:
        """Cached stat for an entry in the current listing.

        Raises OSError on failure (e.g. entry vanished); callers keep their
        existing try/except. Cache is cleared on reload, so a fresh listing
        always re-reads real metadata.
        """
        key = str(p)
        st = self._stat_cache.get(key)
        if st is None:
            st = p.stat()
            self._stat_cache[key] = st
        return st

    def reload(self) -> None:
        # keep the inotify watch on the current root (addPath is a no-op dup)
        if self._root.is_dir():
            self._watcher.addPath(str(self._root))
        else:
            self._watcher.removePath(str(self._root))
        self._stat_cache.clear()
        try:
            entries = [e for e in self._root.iterdir()]
            if not self.show_hidden:
                entries = [e for e in entries if not e.name.startswith(".")]
        except (PermissionError, FileNotFoundError):
            entries = []
        self._all_entries = entries
        self._apply_filter()

    def _on_dir_changed(self, _path: str) -> None:
        """Directory changed on disk — reload (debounced 120ms)."""
        if self._reload_timer is None:
            self._reload_timer = QTimer(self)
            self._reload_timer.setSingleShot(True)
            self._reload_timer.timeout.connect(self.reload)
        self._reload_timer.start(120)

    def _apply_filter(self) -> None:
        """Filter + sort into self._entries, preserving selection by path."""
        entries = self._all_entries
        if self._filter_text:
            needle = self._filter_text.lower()
            entries = [e for e in entries if needle in e.name.lower()]
        entries = self._sort(entries)
        old = {str(e): i for i, e in enumerate(self._entries) if i in self._selected}
        self._entries = entries
        # preserve selection by path across filter changes
        new_sel = {i for i, e in enumerate(entries) if str(e) in old}
        self._selected = new_sel
        self._anchor = None
        self.beginResetModel()
        self.endResetModel()

    def set_root(self, p: Path) -> None:
        if p.resolve() == self._root.resolve():
            self.reload()
            return
        self._root = p
        self._selected.clear()
        self._anchor = None
        self._filter_text = ""  # reset live search on navigation
        self.reload()

    # ---- live search (T10) ----
    def _get_filter_text(self) -> str:
        return self._filter_text

    def _set_filter_text(self, v: str) -> None:
        v = v or ""
        if v == self._filter_text:
            return
        self._filter_text = v
        self._apply_filter()
        self.filterChanged.emit()

    filterText = Property(str, _get_filter_text, _set_filter_text,
                          notify=filterChanged)

    # ---- hidden files checkbox (Task C) ----
    def _get_hidden(self) -> bool:
        return self.show_hidden

    def _set_hidden(self, v: bool) -> None:
        v = bool(v)
        if v == self.show_hidden:
            return
        self.show_hidden = v
        self.reload()
        self.hiddenChanged.emit()

    hiddenProp = Property(bool, _get_hidden, _set_hidden, notify=hiddenChanged)

    # ---- grouping (T10) ----
    def _get_group_mode(self) -> str:
        return self._group_mode

    def _set_group_mode(self, v: str) -> None:
        v = v or "letter"
        if v not in ("letter", "type", "date"):
            v = "letter"
        if v == self._group_mode:
            return
        self._group_mode = v
        self.groupChanged.emit()
        self.dataChanged.emit(self.index(0), self.index(max(0, len(self._entries) - 1)),
                              [self.R_GROUPKEY])

    groupMode = Property(str, _get_group_mode, _set_group_mode,
                         notify=groupChanged)

    def groupKey(self, row: int) -> str:
        """Section header label for a row, per the current group mode."""
        if not (0 <= row < len(self._entries)):
            return ""
        p = self._entries[row]
        mode = self._group_mode
        if mode == "type":
            return "Folders" if p.is_dir() else (p.suffix.lower().lstrip(".").upper() or "Files")
        if mode == "date":
            try:
                ts = self._stat(p).st_mtime
                import datetime as _dt
                d = _dt.date.fromtimestamp(ts)
                today = _dt.date.today()
                if d == today:
                    return "Today"
                if (today - d).days < 7:
                    return "This Week"
                if d.year == today.year and d.month == today.month:
                    return "This Month"
                return str(d.year)
            except (OSError, ValueError):
                return "Unknown"
        # letter
        name = p.name
        ch = name[0].upper() if name else "#"
        return ch if ch.isalpha() else "#"

    def _sort(self, entries: list[Path]) -> list[Path]:
        def key(e: Path):
            try:
                st = self._stat(e)
                if self.sort_key == SortKey.SIZE:
                    k = st.st_size
                elif self.sort_key == SortKey.MODIFIED:
                    k = st.st_mtime
                elif self.sort_key == SortKey.TYPE:
                    k = (e.suffix.lower(), _natkey(e.name))
                else:
                    k = _natkey(e.name)
            except OSError:
                st = None
                k = 0
            # is-dir straight from the cached mode, not a 2nd stat syscall
            isdir = statmod.S_ISDIR(st.st_mode) if st else e.is_dir()
            primary = (0 if isdir else 1) if self.dirs_first else 0
            return (primary, k, e.name.lower())

        out = sorted(entries, key=key)
        if self.sort_desc:
            dirs = [e for e in out if e.is_dir()]
            files = [e for e in out if not e.is_dir()]
            if self.dirs_first:
                return dirs + list(reversed(files))
            return list(reversed(out))
        return out

    # ---- QAbstractListModel ----
    def rowCount(self, parent: QModelIndex = QModelIndex()) -> int:
        return 0 if parent.isValid() else len(self._entries)

    def data(self, index: QModelIndex, role: int = Qt.DisplayRole):
        if not index.isValid() or not (0 <= index.row() < len(self._entries)):
            return None
        p = self._entries[index.row()]
        try:
            st = self._stat(p)
        except OSError:
            st = None
        if role == Qt.DisplayRole or role == self.R_NAME:
            return p.name
        if role == self.R_PATH:
            return str(p)
        if role == self.R_ISDIR:
            return p.is_dir()
        if role == self.R_SIZE:
            return st.st_size if st else 0
        if role == self.R_MODIFIED:
            return int(st.st_mtime) if st else 0
        if role == self.R_TYPE:
            return p.suffix.lower().lstrip(".") if p.is_file() else "Folder"
        if role == self.R_PERMS:
            return _mode_str(st.st_mode) if st else ""
        if role == self.R_OWNER:
            try:
                return pwd.getpwuid(st.st_uid).pw_name if st else ""
            except KeyError:
                return str(st.st_uid) if st else ""
        if role == self.R_GROUP:
            try:
                return grp.getgrgid(st.st_gid).gr_name if st else ""
            except KeyError:
                return str(st.st_gid) if st else ""
        if role == self.R_SELECTED:
            return index.row() in self._selected
        if role == self.R_EXT:
            return p.suffix.lower().lstrip(".")
        if role == self.R_SIZETXT:
            return _human_size(st.st_size) if st and p.is_file() else ""
        if role == self.R_MODTXT:
            return _fmt_time(st.st_mtime) if st else ""
        if role == self.R_ICON:
            return _icon_hint(p)
        if role == self.R_THUMB:
            if p.is_file():
                ext = p.suffix.lower()
                if ext in _IMAGE_EXTS:
                    return p.as_uri()
                if ext in _VIDEO_EXTS or ext in _PDF_EXTS:
                    tp = thumb_path_for(p)
                    if tp.exists() and tp.stat().st_size > 0:
                        return tp.as_uri()
            return ""
        if role == self.R_GROUPKEY:
            return self.groupKey(index.row())
        return None

    def roleNames(self):
        return {
            self.R_NAME: b"fileName",
            self.R_PATH: b"filePath",
            self.R_ISDIR: b"isDir",
            self.R_SIZE: b"fileSize",
            self.R_MODIFIED: b"modified",
            self.R_TYPE: b"fileType",
            self.R_PERMS: b"permissions",
            self.R_OWNER: b"owner",
            self.R_GROUP: b"group",
            self.R_SELECTED: b"selected",
            self.R_EXT: b"extension",
            self.R_SIZETXT: b"sizeText",
            self.R_MODTXT: b"modText",
            self.R_ICON: b"iconName",
            self.R_THUMB: b"thumbUrl",
            self.R_GROUPKEY: b"groupKey",
        }

    # ---- selection ----
    # @Slot: these are called straight from QML MouseArea/Keys handlers
    # (select_click, set_selected, clear_selection, select_all, navigate,
    # typeahead, setSort). Without the decorator PySide6 doesn't expose them
    # to the QML engine, so every mouse/keyboard selection call threw
    # "is not a function" and selection/highlight/context-menu silently died.
    @Slot(int, bool)
    def set_selected(self, row: int, on: bool) -> None:
        if on and row not in self._selected:
            self._selected.add(row)
            self.dataChanged.emit(self.index(row), self.index(row), [self.R_SELECTED])
        elif not on and row in self._selected:
            self._selected.discard(row)
            self.dataChanged.emit(self.index(row), self.index(row), [self.R_SELECTED])

    @Slot()
    def clear_selection(self) -> None:
        rows = list(self._selected)
        self._selected.clear()
        for r in rows:
            self.dataChanged.emit(self.index(r), self.index(r), [self.R_SELECTED])

    @Slot()
    def select_all(self) -> None:
        self._selected = set(range(len(self._entries)))
        if self._entries:
            self.dataChanged.emit(self.index(0), self.index(len(self._entries) - 1))

    def invert_selection(self) -> None:
        self._selected = set(range(len(self._entries))) - self._selected
        if self._entries:
            self.dataChanged.emit(self.index(0), self.index(len(self._entries) - 1))

    def select_range(self, anchor: int, row: int) -> None:
        """Select the inclusive range [min(anchor,row), max(anchor,row)].
        Sets the selection anchor to `row` so repeated Shift+clicks extend."""
        lo, hi = min(anchor, row), max(anchor, row)
        lo = max(0, lo); hi = min(len(self._entries) - 1, hi)
        self._selected.update(range(lo, hi + 1))
        self._anchor = row
        if lo <= hi:
            self.dataChanged.emit(self.index(lo), self.index(hi), [self.R_SELECTED])

    @Slot(int, bool, bool)
    def select_click(self, row: int, ctrl: bool, shift: bool) -> None:
        """Dolphin-style single click. Plain: clear+select (anchor). Ctrl:
        toggle (anchor). Shift: range from anchor (or plain if none yet)."""
        self._current = row
        if ctrl:
            self._anchor = row
            self.set_selected(row, row not in self._selected)
        elif shift and self._anchor is not None:
            self.select_range(self._anchor, row)
        else:
            self._anchor = row
            self.clear_selection()
            self.set_selected(row, True)

    @Slot("QVariantList")
    def set_band(self, rows: list) -> None:
        """Replace the whole selection with exactly `rows` (rubber-band marquee).

        Live-updates during a drag: each onPositionChanged replaces the selected
        set with the rows currently inside the band, so the highlight tracks the
        box instead of only applying on release. A single dataChanged covers
        the touched range.
        """
        sel = {int(r) for r in (rows or []) if 0 <= int(r) < len(self._entries)}
        if sel == self._selected:
            return
        self._selected = sel
        if not self._entries:
            return
        self.dataChanged.emit(self.index(0), self.index(len(self._entries) - 1))

    @Slot(float, float, float, float, float, float, int, float, float, result="QVariantList")
    def rows_in_rect(self, x: float, y: float, w: float, h: float,
                     cell_w: float, cell_h: float, columns: int,
                     ox: float, oy: float) -> list:
        """Row indices whose grid cell overlaps the rect (viewport coords).

        The band geometry and the item cells live in the SAME viewport space
        (both are children of the view; scroll offset is ox/oy). This is the
        source of truth for marquee selection — shared by QML and the headless
        tests, so a broken rubber-band is caught in CI instead of only by hand.
        """
        if columns is None or columns <= 0:
            # QML has no GridView.columns property; callers must pass the real
            # column count. Default to 1 so a mis-wired caller degrades to a
            # single-column band instead of crashing mid-drag.
            columns = 1
        cols = max(1, int(columns))
        out = []
        for i in range(len(self._entries)):
            col, row = i % cols, i // cols
            cx = col * cell_w - ox
            cy = row * cell_h - oy
            if cx < x + w and cx + cell_w > x and cy < y + h and cy + cell_h > y:
                out.append(i)
        return out

    @Slot(int, bool)
    def navigate(self, row: int, shift: bool = False, anchor: int | None = None) -> None:
        """Move keyboard current-row to `row`, clamping to valid bounds. With
        shift, extends the range from the existing anchor (or `anchor` if given).
        Plain: clears previous selection, selects the new current row."""
        n = len(self._entries)
        if n == 0:
            self._current = -1
            return
        row = max(0, min(n - 1, row))
        self._current = row
        if shift:
            base = self._anchor if self._anchor is not None else (anchor if anchor is not None else row)
            self.select_range(base, row)
        else:
            self._anchor = row
            self.clear_selection()
            self.set_selected(row, True)

    @property
    def currentRow(self) -> int:
        return self._current

    @Slot(str, result=int)
    def typeahead(self, buffer: str) -> int:
        """Type-ahead select: jump to the first name starting with `buffer`
        (case-insensitive). Returns the row chosen, or -1 if no match."""
        needle = buffer.lower()
        for i, e in enumerate(self._entries):
            if e.name.lower().startswith(needle):
                self.navigate(i)
                return i
        return -1

    @property
    def selectedRows(self) -> list[int]:
        return sorted(self._selected)

    @property
    def selectedCount(self) -> int:
        return len(self._selected)

    # ---- helpers ----
    def pathForRow(self, row: int) -> Path | None:
        if 0 <= row < len(self._entries):
            return self._entries[row]
        return None

    def notify_thumb(self, path: str) -> None:
        """Emit dataChanged(R_THUMB) for rows matching a path.

        Called on the main thread when the background worker finished
        rendering a poster, so the grid re-reads thumbUrl and swaps the
        icon to the thumbnail without a full model reset.
        """
        for r, e in enumerate(self._entries):
            if str(e) == path:
                self.dataChanged.emit(self.index(r), self.index(r), [self.R_THUMB])

    def toggleHidden(self) -> None:
        self.show_hidden = not self.show_hidden
        self.reload()
        self.hiddenChanged.emit()

    def _get_icon_size(self): return self.icon_size
    def _set_icon_size(self, v): self.icon_size = int(v); self.dataChanged.emit(self.index(0), self.index(max(0, len(self._entries)-1)))
    iconSizeProp = Property(int, _get_icon_size, _set_icon_size)

    @Slot(int, result=bool)
    def isDirAt(self, row: int) -> bool:
        """QML-callable is-dir check. data() is NOT Slot-exposed (role args
        arrive mangled through QML), so raw data(index, R_ISDIR) from QML
        returned the display name — truthy for every file — making
        double-clicked files take the enterDir path and open nothing."""
        p = self.pathForRow(row)
        return p.is_dir() if p else False

    @Slot(int, result="QString")
    def pathAt(self, row: int) -> str:
        p = self.pathForRow(row)
        return str(p) if p else ""

    @Slot(int, bool)
    def setSort(self, key: int, desc: bool = False) -> None:
        self.sort_key = SortKey(key)
        self.sort_desc = desc
        self.reload()

    def setDirsFirst(self, on: bool) -> None:
        self.dirs_first = on
        self.reload()

    def props(self) -> dict:
        """Current view-props, for persistence keyed by folder path."""
        return {
            "iconSize": self.icon_size,
            "sortKey": int(self.sort_key),
            "sortDesc": self.sort_desc,
            "dirsFirst": self.dirs_first,
            "showHidden": self.show_hidden,
        }

    def apply_props(self, props: dict) -> None:
        """Apply saved view-props (subset of keys is fine)."""
        if "iconSize" in props:
            self.icon_size = int(props["iconSize"])
        if "sortKey" in props:
            self.sort_key = SortKey(int(props["sortKey"]))
        if "sortDesc" in props:
            self.sort_desc = bool(props["sortDesc"])
        if "dirsFirst" in props:
            self.dirs_first = bool(props["dirsFirst"])
        if "showHidden" in props:
            self.show_hidden = bool(props["showHidden"])
            self.hiddenChanged.emit()
        self.reload()


def rename_stem(name: str, is_dir: bool = False) -> str:
    """Stem portion of a name to pre-select for inline rename.

    Dolphin parity: a directory or a file with no extension selects the whole
    name; otherwise the text before the last dot is selected. A dotfile such as
    ``.bashrc`` has no selectable extension in Dolphin's eyes, so it is treated
    as a full stem.
    """
    if is_dir:
        return name
    if name.startswith("."):
        return name if "." not in name[1:] else name.rsplit(".", 1)[0]
    return name.rsplit(".", 1)[0] if "." in name else name


def _mode_str(mode: int) -> str:
    return statmod.filemode(mode)


def _human_size(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024:
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


def _fmt_time(ts: float) -> str:
    try:
        return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")
    except (ValueError, OverflowError):
        return ""


def _icon_hint(p: Path) -> str:
    if p.is_dir():
        return "folder"
    ext = p.suffix.lower()
    images = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg", ".tiff"}
    audio = {".mp3", ".wav", ".flac", ".ogg", ".m4a", ".aac"}
    video = {".mp4", ".mkv", ".webm", ".mov", ".avi"}
    if ext in images:
        return "image"
    if ext in audio:
        return "audio"
    if ext in video:
        return "video"
    if ext in {".pdf"}:
        return "pdf"
    if ext in {".zip", ".tar", ".gz", ".xz", ".bz2", ".7z"}:
        return "archive"
    if ext in {".py", ".sh", ".c", ".cpp", ".h", ".rs", ".go", ".js", ".ts", ".html", ".css"}:
        return "code"
    return "text"


if __name__ == "__main__":
    import tempfile

    locale.setlocale(locale.LC_ALL, "C")
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        (root / "file2.txt").write_text("x")
        (root / "file10.txt").write_text("x")
        (root / "afolder").mkdir()
        m = FileSystemModel(root)
        names = [m.data(m.index(i), m.R_NAME) for i in range(m.rowCount())]
        assert names == ["afolder", "file2.txt", "file10.txt"], f"got {names}"
        assert m.data(m.index(0), m.R_ISDIR) is True
        assert m.data(m.index(1), m.R_SIZE) == 1
    print("PASS FileSystemModel natural sort + dirs-first")
