"""Settings — persisted app state (plain JSON at ~/.config/pyre/).

Per PRD §12: window size/position, view mode, docks visibility, sort, zoom,
places list. Plain readable JSON, hand-editable, no binary DB.
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

from PySide6.QtCore import Property, QObject, Signal

CONFIG_DIR = Path.home() / ".config" / "pyre"
CONFIG_FILE = CONFIG_DIR / "settings.json"

DEFAULTS = {
    # window geometry; x/y/w/h == 0 means "never persisted yet" (first run).
    # main.qml fills the screen on first run, then persists real geometry.
    "window": {"x": 0, "y": 0, "width": 0, "height": 0},
    "viewMode": "icons",
    "iconSize": 32,
    "sortKey": 0,
    "sortDesc": False,
    "dirsFirst": True,
    "menuVisible": True,
    "toolbarVisible": True,
    "sidebarVisible": True,
    "infoVisible": False,
    "showHidden": False,
    # per-folder view-properties, keyed by absolute path (PRD §12)
    "folderProps": {},
    # open tabs across restart (absolute paths, last is active)
    "tabs": [],
    # last-visited folder (used when tabs is empty)
    "currentPath": "",
    "places": [
        {"label": "Home", "path": "~"},
        {"label": "Desktop", "path": "~/Desktop"},
        {"label": "Documents", "path": "~/Documents"},
        {"label": "Downloads", "path": "~/Downloads"},
        {"label": "Pictures", "path": "~/Pictures"},
        {"label": "Music", "path": "~/Music"},
        {"label": "Videos", "path": "~/Videos"},
        {"label": "Root", "path": "/"},
    ],
}


class Settings(QObject):
    changed = Signal()

    def __init__(self):
        super().__init__()
        self._data = dict(DEFAULTS)
        self._load()

    def _load(self):
        try:
            data = json.loads(CONFIG_FILE.read_text())
            for k, v in data.items():
                if k == "places":
                    self._data["places"] = v
                elif isinstance(v, dict) and isinstance(self._data.get(k), dict):
                    self._data[k].update(v)
                else:
                    self._data[k] = v
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        self._populate_xdg_dirs()

    def _populate_xdg_dirs(self):
        """Fill standard Places from xdg-user-dirs (keeps saved custom places)."""
        try:
            r = subprocess.run(
                ["xdg-user-dir", "DESKTOP"], capture_output=True, text=True, timeout=5
            )
        except (OSError, subprocess.TimeoutExpired):
            return
        if r.returncode != 0:
            return
        known = {p["label"] for p in self._data["places"]}
        xdg = {"DESKTOP": "Desktop", "DOWNLOAD": "Downloads", "DOCUMENTS": "Documents",
               "PICTURES": "Pictures", "MUSIC": "Music", "VIDEOS": "Videos"}
        for key, label in xdg.items():
            if label in known:
                continue
            try:
                rr = subprocess.run(["xdg-user-dir", key],
                                    capture_output=True, text=True, timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                continue
            d = rr.stdout.strip()
            if d and Path(d).is_dir():
                self._data["places"].append({"label": label, "path": d})

    def save(self):
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        CONFIG_FILE.write_text(json.dumps(self._data, indent=2))

    def get(self, key, default=None):
        return self._data.get(key, default)

    def set(self, key, value):
        if self._data.get(key) != value:
            self._data[key] = value
            self.changed.emit()

    # ---- QML-visible properties (read/write, notify on change) ----
    def _get_viewMode(self): return self._data["viewMode"]
    def _set_viewMode(self, v): self.set("viewMode", v)
    viewModeProp = Property(str, _get_viewMode, _set_viewMode, notify=changed)

    def _get_menuVisible(self): return self._data["menuVisible"]
    def _set_menuVisible(self, v): self.set("menuVisible", v)
    menuVisibleProp = Property(bool, _get_menuVisible, _set_menuVisible, notify=changed)

    def _get_toolbarVisible(self): return self._data["toolbarVisible"]
    def _set_toolbarVisible(self, v): self.set("toolbarVisible", v)
    toolbarVisibleProp = Property(bool, _get_toolbarVisible, _set_toolbarVisible, notify=changed)

    def _get_sidebarVisible(self): return self._data["sidebarVisible"]
    def _set_sidebarVisible(self, v): self.set("sidebarVisible", v)
    sidebarVisibleProp = Property(bool, _get_sidebarVisible, _set_sidebarVisible, notify=changed)

    def _get_infoVisible(self): return self._data["infoVisible"]
    def _set_infoVisible(self, v): self.set("infoVisible", v)
    infoVisibleProp = Property(bool, _get_infoVisible, _set_infoVisible, notify=changed)

    def _get_iconSize(self): return self._data["iconSize"]
    def _set_iconSize(self, v): self.set("iconSize", v)
    iconSizeProp = Property(int, _get_iconSize, _set_iconSize, notify=changed)

    def _get_winX(self): return self._data["window"].get("x", 0)
    def _get_winY(self): return self._data["window"].get("y", 0)
    def _get_winW(self): return self._data["window"].get("width", 0)
    def _get_winH(self): return self._data["window"].get("height", 0)

    def _set_window_key(self, key, value):
        w = self._data["window"]
        if w.get(key) != value:
            w[key] = value
            self.changed.emit()

    def _set_winX(self, v): self._set_window_key("x", int(v))
    def _set_winY(self, v): self._set_window_key("y", int(v))
    def _set_winW(self, v): self._set_window_key("width", int(v))
    def _set_winH(self, v): self._set_window_key("height", int(v))

    winXProp = Property(int, _get_winX, _set_winX, notify=changed)
    winYProp = Property(int, _get_winY, _set_winY, notify=changed)
    winWProp = Property(int, _get_winW, _set_winW, notify=changed)
    winHProp = Property(int, _get_winH, _set_winH, notify=changed)

    @property
    def places(self):
        return self._data["places"]

    # ---- per-folder view-properties (PRD §12) ----
    def get_folder_props(self, path: str) -> dict:
        """Saved view-props for an absolute path, or {} if none."""
        return dict(self._data["folderProps"].get(path, {}))

    def set_folder_props(self, path: str, props: dict) -> None:
        """Record view-props for an absolute path.

        Cap the map at ~200 entries, evicting oldest-inserted first
        (dict preserves insertion order, so the leading keys are the oldest).
        """
        fp = self._data["folderProps"]
        fp[path] = dict(props)
        if len(fp) > 200:
            for k in list(fp)[: len(fp) - 200]:
                del fp[k]
        self.changed.emit()

    # ---- session restore (tabs + last-visited folder) ----
    def get_tabs(self) -> list[str]:
        return list(self._data["tabs"])

    def set_tabs(self, paths: list[str]) -> None:
        self.set("tabs", list(paths))

    def get_current_path(self) -> str:
        return self._data["currentPath"]

    def set_current_path(self, path: str) -> None:
        self.set("currentPath", path)


if __name__ == "__main__":
    s = Settings()
    assert s.viewModeProp == "icons"
    assert s.places[0]["label"] == "Home"
    s.set("viewMode", "details")
    s.save()
    s2 = Settings()
    assert s2.viewModeProp == "details", s2.viewModeProp
    s2.set("viewMode", "icons")
    s2.save()
    print("PASS Settings load/save round-trip")
