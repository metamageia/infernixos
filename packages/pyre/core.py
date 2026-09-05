"""FileController — the app's brain.

Owns navigation (history, enter/up/back/forward), tabs, split-view, and the
file operations. QML talks to this single object. The FileSystemModel for
the active tab lives at self.model; QML binds the view to it and calls
controller methods for actions.

Tabs / split are simple structures here; the model instance per tab is the
heavy part, so a Tab holds its own FileSystemModel.
"""
from __future__ import annotations

import fnmatch
import mimetypes
import os
import queue
import shlex
import shutil
import subprocess
import threading
import urllib.parse
from datetime import datetime
from pathlib import Path

from PySide6.QtCore import Property, QObject, QTimer, Signal, Slot

from fs_model import (
    FileSystemModel,
    SortKey,
    _IMAGE_EXTS,
    _PDF_EXTS,
    _VIDEO_EXTS,
    thumb_path_for,
    thumbnailable,
)


TEXT_EXTS = {
    ".txt", ".md", ".markdown", ".log", ".py", ".sh", ".c", ".cpp", ".h", ".rs",
    ".go", ".js", ".ts", ".html", ".css", ".json", ".yaml", ".yml", ".toml",
    ".ini", ".cfg", ".conf", ".xml", ".csv", ".tex", ".org", ".rst", ".sql",
    ".gitignore", ".env",
}


# ---- freedesktop app resolution (MIME → default app / Open-With list) ----

def _desktop_dirs() -> list[Path]:
    """Directories that can hold *.desktop entries, XDG order, user first."""
    dirs = [Path.home() / ".local/share/applications"]
    for d in os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":"):
        if d:
            dirs.append(Path(d) / "applications")
    dirs.append(Path("/usr/share/applications"))
    seen: set[Path] = set()
    out = []
    for d in dirs:
        if d not in seen:
            seen.add(d)
            out.append(d)
    return out


def _parse_desktop(f: Path) -> dict:
    """Minimal .desktop parser — [Desktop Entry] keys we care about."""
    entry: dict = {}
    in_entry = False
    try:
        lines = f.read_text(errors="replace").splitlines()
    except OSError:
        return entry
    for ln in lines:
        ln = ln.strip()
        if ln.startswith("[") and ln.endswith("]"):
            in_entry = (ln == "[Desktop Entry]")
            continue
        if not in_entry or not ln or ln.startswith("#") or "=" not in ln:
            continue
        k, _, v = ln.partition("=")
        entry[k.strip()] = v.strip()
    return entry


def _mime_matches(declared: str, mime: str) -> bool:
    """Does the app's MimeType= (semicolon list, may use * globs) match?"""
    return any(
        p == mime or (p.endswith("*") and mime.startswith(p[:-1]))
        for p in declared.split(";")
        if p
    )


def _apps_for_mime(mime: str) -> list[dict]:
    """Desktop entries declaring `mime`, as {id, name, icon} sorted by name."""
    apps: dict[str, dict] = {}
    for d in _desktop_dirs():
        if not d.is_dir():
            continue
        for f in sorted(d.glob("*.desktop")):
            if f.name in apps:
                continue
            e = _parse_desktop(f)
            if not e.get("Exec"):
                continue
            if e.get("Hidden") == "true":
                continue
            if _mime_matches(e.get("MimeType", ""), mime):
                apps[f.name] = {
                    "id": f.name,
                    "name": e.get("Name", f.stem),
                    "icon": e.get("Icon", ""),
                }
    return sorted(apps.values(), key=lambda a: a["name"].lower())


def _exec_cmd(entry: dict, desktop_file: Path, path: Path) -> list[str] | None:
    """Expand a .desktop Exec line with the freedesktop field codes for one file."""
    ex = entry.get("Exec", "")
    if not ex:
        return None
    quoted = shlex.quote(str(path))
    uri = path.as_uri()
    has_file_code = any(c in ex for c in ("%f", "%F", "%u", "%U"))
    ex = ex.replace("%f", quoted).replace("%F", quoted)
    ex = ex.replace("%u", uri).replace("%U", uri)
    if entry.get("Icon"):
        ex = ex.replace("%i", f"--icon {shlex.quote(entry['Icon'])}")
    else:
        ex = ex.replace("%i", "")
    ex = ex.replace("%c", shlex.quote(entry.get("Name", "")))
    ex = ex.replace("%k", shlex.quote(str(desktop_file)))
    for dep in ("%d", "%D", "%n", "%N", "%v", "%m"):
        ex = ex.replace(dep, "")
    if not has_file_code:
        ex = f"{ex} {quoted}"
    try:
        return shlex.split(ex)
    except ValueError:
        return None


def _launch_desktop(app_id: str, path: Path) -> bool:
    """Find app_id's .desktop, expand its Exec for `path`, launch detached."""
    for d in _desktop_dirs():
        f = d / app_id
        if not f.is_file():
            continue
        cmd = _exec_cmd(_parse_desktop(f), f, path)
        if not cmd:
            return False
        try:
            subprocess.Popen(
                cmd,
                start_new_session=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            return True
        except OSError:
            return False
    return False


def _set_default(mime: str, app_id: str) -> None:
    """Persist app_id as the default for mime (xdg-mime, else write mimeapps.list)."""
    try:
        subprocess.run(
            ["xdg-mime", "default", app_id, mime], timeout=10, check=True
        )
        return
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        pass
    p = Path.home() / ".config" / "mimeapps.list"
    try:
        lines = p.read_text().splitlines() if p.exists() else []
    except OSError:
        lines = []
    section = "[Default Applications]"
    if section not in lines:
        lines += ["", section]
    key = f"{mime}={app_id}"
    out: list[str] = []
    in_sec, replaced = False, False
    for ln in lines:
        if ln == section:
            in_sec = True
            out.append(ln)
            continue
        if in_sec and ln.startswith("[") and ln != section:
            in_sec = False
        if in_sec and ln.startswith(mime + "="):
            out.append(key)
            replaced = True
            continue
        out.append(ln)
    if not replaced:
        for i, ln in enumerate(out):
            if ln == section:
                out.insert(i + 1, key)
                break
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("\n".join(out) + "\n")
    except OSError:
        pass


def _find_trashed(orig: str) -> str:
    """Path of the trashed copy of `orig`, matched via trashinfo Path= (authoritative)."""
    info_dir = Path.home() / ".local/share/Trash/info"
    if not info_dir.is_dir():
        return ""
    for info in info_dir.glob("*.trashinfo"):
        try:
            val = next((ln.split("=", 1)[1].strip() for ln in
                        info.read_text().splitlines()
                        if ln.startswith("Path=")), "")
        except OSError:
            continue
        if urllib.parse.unquote(val) == orig:
            return str(Path.home() / ".local/share/Trash/files" / info.stem)
    return ""


def _gio_trash(p: Path) -> bool:
    """Trash via `gio trash` (correct cross-fs + restore metadata). False if gio missing."""
    try:
        r = subprocess.run(["gio", "trash", str(p)], capture_output=True, timeout=30)
        return r.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _to_trash(p: Path):
    """Move to XDG trash. gio first; fallback is a local-fs-only implementation."""
    if _gio_trash(p):
        return
    # ponytail: fallback ignores the same-filesystem rule (cross-fs moves copy,
    # possibly slow); gio covers the real path.
    trash = Path.home() / ".local" / "share" / "Trash"
    files = trash / "files"
    info = trash / "info"
    files.mkdir(parents=True, exist_ok=True)
    info.mkdir(parents=True, exist_ok=True)
    dest = files / p.name
    i = 1
    base = dest
    while dest.exists():
        dest = files / f"{base.stem}_{i}{base.suffix}"
        i += 1
    if p.stat().st_dev != files.stat().st_dev:
        raise OSError(f"{p} is on another filesystem; install gio to trash it")
    shutil.move(str(p), str(dest))
    # trashinfo metadata (best effort; KDE-compatible name); Path URI-encoded
    (info / f"{dest.name}.trashinfo").write_text(
        f"[Trash Info]\nPath={urllib.parse.quote(str(p.resolve()))}\n"
        f"DeletionDate={datetime.now().astimezone().isoformat(timespec='seconds')}\n"
    )


_MIME_CACHE: dict[str, str] = {}


def _mime_for(p: Path) -> str:
    """MIME type of a file — xdg-mime query, falling back to stdlib mimetypes."""
    key = f"{p}:{p.stat().st_mtime_ns}:{p.stat().st_size}" if p.exists() else str(p)
    hit = _MIME_CACHE.get(key)
    if hit is not None:
        return hit
    m = ""
    try:
        r = subprocess.run(
            ["xdg-mime", "query", "filetype", str(p)],
            capture_output=True, text=True, timeout=10,
        )
        m = r.stdout.strip()
        if m:
            hit = m.split(";")[0].strip()
        else:
            hit = mimetypes.guess_type(str(p))[0] or "application/octet-stream"
    except (OSError, subprocess.TimeoutExpired):
        hit = mimetypes.guess_type(str(p))[0] or "application/octet-stream"
    _MIME_CACHE[key] = hit
    return hit


def _default_app(mime: str) -> str:
    """Default app id for mime, or \"\" — xdg-mime query default."""
    try:
        r = subprocess.run(
            ["xdg-mime", "query", "default", mime],
            capture_output=True, text=True, timeout=10,
        )
        return r.stdout.strip().splitlines()[0].strip() if r.stdout.strip() else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def preview_text(p: Path, limit: int = 4000) -> str:
    """Return the first `limit` chars of a text file, or "" for non-text files."""
    if not p.is_file() or p.suffix.lower() not in TEXT_EXTS:
        return ""
    try:
        data = p.read_bytes()[:limit]
    except OSError:
        return ""
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("latin-1", errors="replace")


def poster_for(p: Path) -> str:
    """Render a poster thumbnail for a video/PDF file into the cache dir.

    Returns the cache file URI on success, "" on failure. Videos use ffmpeg
    (``-ss 1 -frames:v 1``); PDFs use pdftoppm first page. The result is
    cached at ``thumb_path_for(p)``, so repeat calls are a cheap check.
    """
    if not thumbnailable(p):
        return ""
    tp = thumb_path_for(p)
    if tp.exists() and tp.stat().st_size > 0:
        return tp.as_uri()
    try:
        tp.parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        return ""
    ext = p.suffix.lower()
    try:
        if ext in _VIDEO_EXTS:
            tmp = tp.with_suffix(".tmp.png")
            r = subprocess.run(
                ["ffmpeg", "-y", "-ss", "1", "-i", str(p), "-frames:v", "1", str(tmp)],
                capture_output=True, timeout=60,
            )
            if r.returncode == 0 and tmp.exists() and tmp.stat().st_size > 0:
                os.replace(tmp, tp)
        elif ext in _PDF_EXTS:
            prefix = tp.with_name(tp.stem + "_pg")
            r = subprocess.run(
                ["pdftoppm", "-f", "1", "-l", "1", "-png", "-r", "150", str(p), str(prefix)],
                capture_output=True, timeout=60,
            )
            if r.returncode == 0:
                pages = sorted(prefix.parent.glob(prefix.name + "*.png"))
                if pages and pages[0].stat().st_size > 0:
                    os.replace(pages[0], tp)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return tp.as_uri() if tp.exists() and tp.stat().st_size > 0 else ""


class ThumbnailWorker(QObject):
    """Background poster renderer (daemon thread); never blocks the UI thread.

    QML/the grid request posters by path via request(); the worker renders
    them in a daemon thread and emits ``thumbReady(path, uri)``. Cross-thread
    signal emission auto-queues to the main thread, so the model update that
    swaps icons to thumbnails happens on the UI thread.
    """
    thumbReady = Signal(str, str)

    def __init__(self):
        super().__init__()
        self._q: queue.Queue = queue.Queue()
        self._seen: set[str] = set()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def request(self, path: str) -> None:
        if path in self._seen:
            return
        self._seen.add(path)
        self._q.put(path)

    def shutdown(self) -> None:
        self._q.put(None)

    def _run(self) -> None:
        while True:
            path = self._q.get()
            if path is None:
                return
            uri = poster_for(Path(path))
            self.thumbReady.emit(path, uri)


class _Tab:
    __slots__ = ("model",)

    def __init__(self, model: FileSystemModel):
        self.model = model


class FileController(QObject):
    currentPathChanged = Signal(str)
    tabChanged = Signal(int)
    statusChanged = Signal(str)
    selectionChanged = Signal(int)  # count
    splitChanged = Signal(bool)
    previewChanged = Signal()
    openWithRequested = Signal(str, str)  # path, mime — no default app set
    opsProgress = Signal(int, int)  # done, total
    opsDone = Signal(str)  # error, "" on success
    busyChanged = Signal()
    trashResults = Signal("QVariantList")  # [(kind, trashedPath, origPath)]

    def __init__(self, settings=None):
        super().__init__()
        self._settings = settings
        self._tabs: list[_Tab] = [_Tab(FileSystemModel(Path.home()))]
        self._active = 0
        # per-tab navigation history
        self._back: list[list[str]] = [[]]
        self._fwd: list[list[str]] = [[]]
        self._model = self._tabs[0].model
        self._model.currentChanged.connect(self._on_current_changed)
        self._model.dataChanged.connect(self._filter_data_changed)
        self._clip: list[Path] = []
        self._cut = False
        self._split_model = FileSystemModel(Path.home())
        self._split_visible = False
        # stack of closed tabs: (path, index) — for Ctrl+Shift+T reopen
        self._closed: list[tuple[str, int]] = []
        # lazy poster thumbnails: background worker populates R_THUMB URLs
        self._thumb_worker = ThumbnailWorker()
        self._thumb_worker.thumbReady.connect(self._on_thumb_ready)
        # async file ops + undo
        self.opsDone.connect(self._on_ops_done)
        self.trashResults.connect(self._on_trash_results)
        self._busy = False
        self._cancel_ops = False
        self._undo_log: list[tuple[str, str, str]] = []
        # paths already handed to the worker; lets the 1.5s tick skip the
        # whole directory instead of re-stat'ing every row on the UI thread
        self._thumb_scanned: set[str] = set()
        self._thumb_timer = QTimer(self)
        self._thumb_timer.timeout.connect(self._schedule_thumbs)
        self._thumb_timer.start(1500)
        self._schedule_thumbs()

    # ---- QML-facing properties (read directly off self._model) ----
    @property
    def model(self) -> FileSystemModel:
        return self._model

    def _get_currentPath(self) -> str:
        return str(self._model.root)

    currentPath = property(_get_currentPath)
    currentPathProp = Property(str, _get_currentPath, notify=currentPathChanged)

    # ---- navigation ----
    @Slot(int)
    def enterDir(self, row: int):
        p = self._model.pathForRow(row)
        if p and p.is_dir():
            self._push_back()
            self._go(p)

    @Slot(str)
    def openPath(self, path: str):
        """Enter an absolute path (location bar / places / search result)."""
        p = Path(path).expanduser()
        if not p.exists():
            self.statusChanged.emit(f"No such file or directory: {path}")
            return
        if p.is_dir():
            self._push_back()
            self._go(p)
        else:
            self._open_file(p)

    @Slot(str)
    def openUri(self, uri: str):
        """Open a URI — local paths, or remote locations via gio open."""
        if uri.startswith("file://"):
            self.openPath(urllib.parse.unquote(urllib.parse.urlparse(uri).path))
            return
        try:
            subprocess.Popen(["gio", "open", uri], start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as e:
            self.statusChanged.emit(str(e))

    @Slot(str)
    def revealPath(self, path: str):
        """Open the containing folder of a file and select it (reveal-in-place).

        Used by advanced-search results: click a hit and you land in its
        parent folder with the file highlighted, instead of just launching it.
        """
        p = Path(path).expanduser()
        if not p.exists():
            self.statusChanged.emit(f"No such file or directory: {path}")
            return
        parent = p.parent if p.is_file() else p
        self._push_back()
        self._go(parent)
        if p.is_file():
            for row in range(self._model.rowCount()):
                if self._model.pathForRow(row) == p:
                    self._model.clear_selection()
                    self._model.set_selected(row, True)
                    break

    @Slot()
    def goUp(self):
        parent = self._model.root.parent
        if parent != self._model.root:
            self._push_back()
            self._go(parent)

    @Slot()
    def goBack(self):
        if self._back[self._active]:
            self._fwd[self._active].append(self.currentPath)
            self._go(Path(self._back[self._active].pop()))

    @Slot()
    def goForward(self):
        if self._fwd[self._active]:
            self._back[self._active].append(self.currentPath)
            self._go(Path(self._fwd[self._active].pop()))

    @Slot()
    def goHome(self):
        self._push_back()
        self._go(Path.home())

    @Slot()
    def goRoot(self):
        self._push_back()
        self._go(Path("/"))

    def _push_back(self):
        if not self._back[self._active] or self._back[self._active][-1] != self.currentPath:
            self._back[self._active].append(self.currentPath)
        self._fwd[self._active].clear()

    def _go(self, p: Path):
        self._save_folder_props()
        self._model.set_root(p)
        self._load_folder_props(p)
        self._on_current_changed()

    def _on_current_changed(self):
        self.currentPathChanged.emit(self.currentPath)
        self.previewChanged.emit()
        self.statusChanged.emit(self._model.statusText)
        self.tabChanged.emit(self._active)

    # ---- per-folder view-properties (PRD §12) ----
    def _save_folder_props(self):
        """Persist the active folder's view-props before leaving it."""
        if self._settings is None:
            return
        props = self._model.props()
        props["mode"] = self._settings.viewModeProp
        self._settings.set_folder_props(str(self._model.root), props)

    def _load_folder_props(self, p: Path):
        """Apply saved view-props for a folder we just entered (if any)."""
        if self._settings is None:
            return
        props = self._settings.get_folder_props(str(p))
        if not props:
            return
        self._model.apply_props(props)
        if "mode" in props:
            self._settings.viewModeProp = props["mode"]

    # ---- session restore (tabs + last-visited folder) ----
    def save_session(self):
        """Persist open tabs + last-visited folder (call on quit)."""
        if self._settings is None:
            return
        self._save_folder_props()
        self._settings.set_tabs([str(t.model.root) for t in self._tabs])
        self._settings.set_current_path(self.currentPath)

    def restore_session(self):
        """Reopen tabs / last-visited folder from settings (call on startup).

        Tabs win over last-visited folder when both are present. If neither,
        the controller stays on its default (home).
        """
        if self._settings is None:
            return
        tabs = self._settings.get_tabs()
        if tabs:
            paths = [Path(t) for t in tabs if t]
            if paths:
                self._tabs = [_Tab(FileSystemModel(p)) for p in paths]
                self._back = [[] for _ in paths]
                self._fwd = [[] for _ in paths]
                self._active = len(paths) - 1
                self._model = self._tabs[self._active].model
                self._model.currentChanged.connect(self._on_current_changed)
                self._model.dataChanged.connect(self._filter_data_changed)
                self._load_folder_props(self._model.root)
                self._on_current_changed()
                return
        cp = self._settings.get_current_path()
        if cp and Path(cp).is_dir():
            self._model.set_root(Path(cp))
            self._load_folder_props(Path(cp))
            self._on_current_changed()

    # ---- tabs ----
    @Slot(str)
    def newTab(self, path: str = ""):
        p = Path(path or self.currentPath)
        tab = _Tab(FileSystemModel(p))
        self._tabs.append(tab)
        self._back.append([])
        self._fwd.append([])
        self._set_active(len(self._tabs) - 1)

    @Slot(int)
    def closeTab(self, index: int):
        if len(self._tabs) <= 1:
            return
        self._closed.append((str(self._tabs[index].model.root), index))
        del self._tabs[index]
        del self._back[index]
        del self._fwd[index]
        self._set_active(min(index, len(self._tabs) - 1))

    @Slot(int, int)
    def moveTab(self, from_index: int, to_index: int):
        """Reorder a tab (drag in the tab bar). Clamps to valid range."""
        if not self._tabs:
            return
        from_index = max(0, min(from_index, len(self._tabs) - 1))
        to_index = max(0, min(to_index, len(self._tabs) - 1))
        if from_index == to_index:
            return
        tab = self._tabs.pop(from_index)
        back = self._back.pop(from_index)
        fwd = self._fwd.pop(from_index)
        self._tabs.insert(to_index, tab)
        self._back.insert(to_index, back)
        self._fwd.insert(to_index, fwd)
        # active tab follows the moved tab
        if self._active == from_index:
            self._active = to_index
        elif from_index < self._active <= to_index:
            self._active -= 1
        elif to_index <= self._active < from_index:
            self._active += 1
        self.tabChanged.emit(self._active)

    @Slot(int)
    def setActiveTab(self, index: int):
        """Switch to the given tab (click in the tab bar)."""
        if 0 <= index < len(self._tabs):
            self._set_active(index)

    @Slot()
    def reopenTab(self):
        """Reopen the most recently closed tab (Ctrl+Shift+T)."""
        if not self._closed:
            return
        path, index = self._closed.pop()
        p = Path(path)
        # clamp index to current tab count; a closed trailing tab lands at the end
        index = min(index, len(self._tabs))
        self._tabs.insert(index, _Tab(FileSystemModel(p)))
        self._back.insert(index, [])
        self._fwd.insert(index, [])
        self._set_active(index)

    @Slot()
    def nextTab(self):
        self._set_active((self._active + 1) % len(self._tabs))

    @Slot()
    def prevTab(self):
        self._set_active((self._active - 1) % len(self._tabs))

    def _set_active(self, index: int):
        self._save_folder_props()
        self._active = index
        self._model.currentChanged.disconnect(self._on_current_changed)
        self._model = self._tabs[index].model
        self._model.currentChanged.connect(self._on_current_changed)
        if not getattr(self._model, "_connected", False):
            self._model.dataChanged.connect(self._filter_data_changed)
            self._model._connected = True
        self._load_folder_props(self._model.root)
        self.tabChanged.emit(index)
        self._on_current_changed()

    def _get_tabCount(self) -> int:
        return len(self._tabs)

    tabCount = property(_get_tabCount)
    tabCountProp = Property(int, _get_tabCount, notify=tabChanged)

    def _get_activeIndex(self) -> int:
        return self._active

    activeIndex = property(_get_activeIndex)
    activeIndexProp = Property(int, _get_activeIndex, notify=tabChanged)

    def _get_tabPaths(self) -> list:
        return [str(t.model.root) for t in self._tabs]

    tabPaths = property(_get_tabPaths)
    tabPathsProp = Property("QVariantList", _get_tabPaths, notify=tabChanged)

    # ---- split view (F3) ----
    def _get_splitVisible(self) -> bool:
        return self._split_visible

    splitVisibleProp = Property(bool, _get_splitVisible, notify=splitChanged)

    def _get_busy(self) -> bool:
        return self._busy

    busyProp = Property(bool, _get_busy, notify=busyChanged)

    @Slot()
    def toggleSplit(self):
        self._split_visible = not self._split_visible
        if self._split_visible:
            self._split_model.set_root(self._model.root)
        self.splitChanged.emit(self._split_visible)

    @property
    def splitModel(self) -> FileSystemModel:
        return self._split_model

    # ---- file operations ----
    @Slot(int)
    def openRow(self, row: int):
        p = self._model.pathForRow(row)
        if p is None:
            return
        if p.is_dir():
            self.enterDir(row)
        else:
            self._open_file(p)
    @Slot(result="QString")
    def selectedName(self) -> str:
        """Name of the currently selected row (for dialogs)."""
        rows = self._model.selectedRows
        if rows:
            p = self._model.pathForRow(rows[0])
            return p.name if p else ""
        return ""

    @Slot(result="int")
    def selectedRow(self) -> int:
        rows = self._model.selectedRows
        return rows[0] if rows else -1

    @Slot(int, str)
    def renameRow(self, row: int, new_name: str):
        p = self._model.pathForRow(row)
        if p is None or not new_name or "/" in new_name:
            return
        try:
            p.rename(p.with_name(new_name))
            self._model.reload()
        except OSError as e:
            self.statusChanged.emit(str(e))

    @Slot(int)
    def trashRow(self, row: int):
        """Move to XDG trash (async; undoable)."""
        if self._busy:
            return
        rows = self._model.selectedRows or ([row] if self._model.pathForRow(row) else [])
        pairs = []
        for r in rows:
            p = self._model.pathForRow(r)
            if p is None:
                continue
            pairs.append((p, p))
        if not pairs:
            return
        self._busy = True
        self.statusChanged.emit(f"Trashing {len(pairs)} item(s)…")

        def work():
            done, err = 0, ""
            undo_trash: list[tuple[str, str, str]] = []
            for src, _ in pairs:
                if self._cancel_ops:
                    break
                try:
                    orig = str(src.resolve())
                    _to_trash(src)
                    trashed = _find_trashed(orig)
                    undo_trash.append(("trash", trashed or "", orig))
                except OSError as e:
                    err = str(e)
                done += 1
                self.opsProgress.emit(done, len(pairs))
            self._busy = False
            self._cancel_ops = False
            self._undo_log.extend((k, t, o) for k, t, o in undo_trash if t)
            self.trashResults.emit(undo_trash)
            self.opsDone.emit(err)

        threading.Thread(target=work, daemon=True).start()

    @Slot(str, str, bool, str)
    def openWithCommand(self, path: str, command: str, remember: bool = False,
                        mime: str = ""):
        """Open `path` with a raw command string (%f expanded, else appended).

        remember+mime: also derive a .desktop id from the command's first word
        and persist it as the mime default, so a manual choice sticks.
        """
        p = Path(path)
        quoted = shlex.quote(str(p))
        cmd = command.replace("%f", quoted).replace("%F", quoted)
        try:
            argv = shlex.split(cmd)
        except ValueError:
            argv = []
        if not any(c in command for c in ("%f", "%F", "%u", "%U")):
            argv = argv + [quoted]
        if not argv:
            self.statusChanged.emit("Empty command")
            return
        if remember and mime:
            exe = Path(argv[0]).name
            for d in _desktop_dirs():
                for f in d.glob(f"{exe}*.desktop"):
                    e = _parse_desktop(f)
                    if e.get("Exec", "").startswith(exe):
                        _set_default(mime, f.name)
                        break
                else:
                    continue
                break
        try:
            subprocess.Popen(argv, start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as e:
            self.statusChanged.emit(str(e))

    @Slot(str, str, bool)
    def renameBatch(self, find: str, replace: str, regex: bool):
        """Rename all selected files, replacing `find` with `replace` in names."""
        import re as _re
        count, err = 0, ""
        for row in self._model.selectedRows:
            p = self._model.pathForRow(row)
            if p is None:
                continue
            if regex:
                try:
                    new_name = _re.sub(find, replace, p.name)
                except _re.error as e:
                    self.statusChanged.emit(f"Bad regex: {e}")
                    return
            else:
                new_name = p.name.replace(find, replace)
            if new_name and new_name != p.name and "/" not in new_name:
                try:
                    p.rename(p.with_name(new_name))
                    count += 1
                except OSError as e:
                    err = str(e)
        if err:
            self.statusChanged.emit(err)
        elif count:
            self.statusChanged.emit(f"Renamed {count} item(s)")
        self._model.reload()

    @Slot()
    def cancelOp(self):
        self._cancel_ops = True

    @Slot(str)
    def newFolder(self, name: str = "New Folder"):
        p = self._model.root / name
        i = 1
        while p.exists():
            i += 1
            p = self._model.root / f"{name} {i}"
        try:
            p.mkdir()
            self._model.reload()
        except OSError as e:
            self.statusChanged.emit(str(e))

    @Slot()
    def refresh(self):
        self._model.reload()

    # ---- clipboard (copy/cut/paste) ----
    def _set_clipboard(self, paths: list[Path], cut: bool):
        self._clip = list(paths)
        self._cut = cut
        self.statusChanged.emit(
            f"{len(paths)} item(s) {'cut' if cut else 'copied'} — paste with Ctrl+V"
        )

    @Slot()
    def copySelection(self):
        rows = self._model.selectedRows
        self._set_clipboard([self._model.pathForRow(r) for r in rows if self._model.pathForRow(r)], False)

    @Slot()
    def cutSelection(self):
        rows = self._model.selectedRows
        self._set_clipboard([self._model.pathForRow(r) for r in rows if self._model.pathForRow(r)], True)

    @Slot()
    def paste(self):
        if self._busy or not self._clip:
            return
        dest = self._model.root
        pairs = []
        for src in self._clip:
            if not src.exists():
                continue
            target = dest / src.name
            i = 1
            base = target
            while target.exists():
                target = dest / f"{base.stem}_{i}{base.suffix}"
                i += 1
            pairs.append((src, target))
        if not pairs:
            return
        self._clip = []
        self._run_ops(pairs, cut=self._cut)

    @Slot("QVariantList", bool)
    def dropInto(self, paths: list, move: bool):
        """Copy (or move) externally-dropped paths into the current folder."""
        if self._busy or not paths:
            return
        dest = self._model.root
        pairs = []
        for s in paths:
            src = Path(urllib.parse.unquote(urllib.parse.urlparse(str(s)).path)) \
                if str(s).startswith("file://") else Path(str(s))
            if not src.exists() or src.parent == dest:
                continue
            target = dest / src.name
            i = 1
            base = target
            while target.exists():
                target = dest / f"{base.stem}_{i}{base.suffix}"
                i += 1
            pairs.append((src, target))
        if pairs:
            self._run_ops(pairs, cut=move)

    # ---- async file operations (background thread + undo log) ----
    def _run_ops(self, pairs: list[tuple[Path, Path]], cut: bool):
        """Run copy/move pairs in the worker thread with progress + undo."""
        self._busy = True
        self.statusChanged.emit(f"{len(pairs)} item(s) {'moving' if cut else 'copying'}…")

        def work():
            done, err = 0, ""
            for src, dst in pairs:
                if self._cancel_ops:
                    break
                try:
                    if cut:
                        shutil.move(str(src), str(dst))
                    elif src.is_dir():
                        shutil.copytree(str(src), str(dst))
                    else:
                        shutil.copy2(str(src), str(dst))
                    self._undo_log.append((("move" if cut else "copy"), str(dst), str(src)))
                except OSError as e:
                    err = str(e)
                done += 1
                self.opsProgress.emit(done, len(pairs))
            self._busy = False
            self._cancel_ops = False
            self.opsDone.emit(err)

        threading.Thread(target=work, daemon=True).start()

    def _on_trash_results(self, results: list):
        for kind, trashed, orig in results:
            if trashed:
                self._undo_log.append((kind, trashed, orig))

    def _on_ops_done(self, err: str):
        self._busy = False
        self._cancel_ops = False
        if err:
            self.statusChanged.emit(err)
        else:
            self.statusChanged.emit(
                f"Done — Ctrl+Z to undo ({len(self._undo_log)} undoable step(s))")
        for m in self._all_models():
            m.reload()
        self.busyChanged.emit()

    @Slot()
    def undo(self):
        """Undo the most recent op in the log (copy/move/trash)."""
        if self._busy or not self._undo_log:
            self.statusChanged.emit("Nothing to undo")
            return
        kind, a, b = self._undo_log.pop()
        try:
            if kind == "copy":
                shutil.rmtree(a) if Path(a).is_dir() else Path(a).unlink()
            elif kind == "move":
                shutil.move(a, b)
            elif kind == "trash":
                # restore from trash: a is the trashed path, b the original
                shutil.move(a, b)
        except OSError as e:
            self.statusChanged.emit(f"Undo failed: {e}")
            return
        self.statusChanged.emit(f"Undid {kind}")
        for m in self._all_models():
            m.reload()

    @Slot()
    def selectAll(self):
        self._model.select_all()

    @Slot()
    def invertSelection(self):
        self._model.invert_selection()

    # ---- previews (T6) ----
    def _selected_path(self) -> Path | None:
        rows = self._model.selectedRows
        if rows:
            return self._model.pathForRow(rows[0])
        return None

    @Slot(result="QString")
    def selectedExt(self) -> str:
        """Lowercased extension of the selected file ("" for dirs/none)."""
        p = self._selected_path()
        return p.suffix.lower().lstrip(".") if p else ""

    @Slot(result="QString")
    def selectedFilePath(self) -> str:
        p = self._selected_path()
        return str(p) if p else ""

    @Slot(result="QVariantList")
    def selectedFilePaths(self) -> list:
        return [str(self._model.pathForRow(r)) for r in self._model.selectedRows
                if self._model.pathForRow(r)]

    @Slot("QVariantList", str)
    def askHermes(self, paths: list, question: str = ""):
        """Hand the exact selected paths to infernixos-ask (argv, no shell)."""
        args = ["infernixos-ask"]
        for p in paths or []:
            args += ["--file", str(p)]
        args.append(question or "Explain this")
        try:
            subprocess.Popen(args, start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as e:
            self.statusChanged.emit(f"infernixos-ask: {e}")

    def _filter_data_changed(self, topLeft, bottomRight, roles) -> None:
        """Emit previewChanged when selection flips, so QML bindings refresh."""
        if not roles or FileSystemModel.R_SELECTED in roles:
            self.previewChanged.emit()

    @Slot(str, result="QString")
    def previewTextFor(self, path: str) -> str:
        """Text content (first ~4000 chars) for a text file, else ""."""
        try:
            return preview_text(Path(path))
        except OSError:
            return ""

    @Slot(result="QString")
    def previewImageUri(self) -> str:
        """URI for the preview pane: an image file itself, or a video/PDF poster."""
        p = self._selected_path()
        if not p or not p.is_file():
            return ""
        ext = p.suffix.lower()
        if ext in _IMAGE_EXTS:
            return p.as_uri()
        if ext in _VIDEO_EXTS or ext in _PDF_EXTS:
            return poster_for(p)
        return ""

    def _get_selectedName(self) -> str:
        return self.selectedName()
    selectedNameProp = Property(str, _get_selectedName, notify=previewChanged)

    def _get_selectedExt(self) -> str:
        p = self._selected_path()
        return p.suffix.lower().lstrip(".") if p else ""
    selectedExtProp = Property(str, _get_selectedExt, notify=previewChanged)

    def _get_selectedFilePath(self) -> str:
        p = self._selected_path()
        return str(p) if p else ""
    selectedFilePathProp = Property(str, _get_selectedFilePath, notify=previewChanged)

    def _get_previewImageUri(self) -> str:
        return self.previewImageUri()
    previewImageUriProp = Property(str, _get_previewImageUri, notify=previewChanged)

    def _get_previewText(self) -> str:
        p = self._selected_path()
        return preview_text(p) if p else ""
    previewTextProp = Property(str, _get_previewText, notify=previewChanged)

    # ---- lazy thumbnails (T6) ----
    # ---- lazy thumbnails (T6) ----
    def _all_models(self) -> set:
        models = {t.model for t in self._tabs}
        models.add(self._split_model)
        return models

    def _schedule_thumbs(self) -> None:
        """Enqueue missing video/PDF posters, once per path per listing.

        Each entry is checked exactly once: after it's seen we record it and
        never re-stat it on later ticks. New folders / renamed files carry new
        paths and get scanned on their own. This keeps the 1.5s tick O(seen)
        set-lookups instead of an O(N) stat pass over every model on the UI
        thread. ponytail: a poster that failed to render is not retried until
        the file is navigated-away-and-back (previously it retried every 1.5s
        and never succeeded anyway).
        """
        for m in self._all_models():
            for r in range(m.rowCount()):
                p = m.pathForRow(r)
                if not p or str(p) in self._thumb_scanned:
                    continue
                self._thumb_scanned.add(str(p))
                if thumbnailable(p) and not thumb_path_for(p).exists():
                    self._thumb_worker.request(str(p))

    def _on_thumb_ready(self, path: str, uri: str) -> None:
        """Main thread: tell every model to re-read thumbUrl for that path."""
        for m in self._all_models():
            m.notify_thumb(path)

    # ---- open-with flow (freedesktop MIME resolution) ----
    @Slot(str, result="QVariantList")
    def appsForMime(self, mime: str):
        """Apps that declare `mime` support, as [{id, name, icon}]."""
        return _apps_for_mime(mime)

    @Slot(str, str, bool)
    def openWith(self, path: str, app_id: str, remember: bool):
        """Open `path` with `app_id`; if remember, persist it as the default."""
        p = Path(path)
        mime = _mime_for(p)
        if remember and mime:
            _set_default(mime, app_id)
        if not _launch_desktop(app_id, p):
            self.statusChanged.emit(f"Could not launch {app_id}")

    def _open_file(self, p: Path):
        """Open a file with its default app; if none is set, ask the user
        (emit openWithRequested so QML raises the Open-With chooser)."""
        mime = _mime_for(p)
        default = _default_app(mime)
        if default:
            if _launch_desktop(default, p):
                return
            # default app failed to launch — fall through to the chooser
        self.openWithRequested.emit(str(p), mime)


if __name__ == "__main__":
    # self-check
    c = FileController()
    home = Path.home()
    assert c.model.root == home
    # enter the first subdir present
    first_dir = next((e for e in home.iterdir() if e.is_dir()), None)
    if first_dir:
        row = c.model.rowCount() and next(
            (i for i in range(c.model.rowCount()) if c.model.pathForRow(i) == first_dir), 0
        )
        c.enterDir(row)
        assert c.model.root == first_dir, f"{c.model.root} != {first_dir}"
        c.goUp()
        assert c.model.root == home
    # clipboard copy/paste round-trip (async ops: wait for opsDone)
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "a.txt"
        src.write_text("hi")
        c._clip = [src]
        c._cut = False
        destdir = Path(td) / "dest"
        destdir.mkdir()
        c._model.set_root(destdir)
        c.paste()
        import time
        for _ in range(100):
            if (destdir / "a.txt").exists() and not c._busy:
                break
            time.sleep(0.1)
        assert (destdir / "a.txt").exists(), "paste failed"
        # undo round-trip
        c.undo()
        for _ in range(100):
            if not (destdir / "a.txt").exists():
                break
            time.sleep(0.1)
        assert not (destdir / "a.txt").exists(), "undo failed"
    # split toggle
    c.toggleSplit()
    assert c.splitVisibleProp is True
    assert c.splitModel.root == c.model.root
    c.toggleSplit()
    assert c.splitVisibleProp is False
    print("PASS FileController navigation + clipboard + split")
