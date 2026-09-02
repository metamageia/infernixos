"""ThemeManager — the live-reload differentiator (PRD §11).

wallust renders a Theme.qml (a QtObject with named color properties) into
the app's qml/ dir. A QFileSystemWatcher watches it; on change we re-load
the QQmlComponent and swap the object. QML binds all colors to theme.theme.*,
so a wallust wallpaper switch re-themes the app in place — no restart, no
folder-state loss.

A built-in fallback theme ships in the repo so the app runs without wallust.

When pyre is Nix-installed the bundled qml/Theme.qml is a read-only Nix-store
path wallust can never write, so wallust renders to ~/.config/pyre/Theme.qml
instead. ThemeManager prefers that writable path when it exists and falls back
to the bundled copy otherwise, so live theming works both uninstalled (dev)
and installed (Nix).
"""
from __future__ import annotations

import sys
from pathlib import Path

from PySide6.QtCore import Property, QFileSystemWatcher, QObject, QUrl, Signal
from PySide6.QtQml import QQmlComponent, QQmlEngine

APP_DIR = Path(__file__).resolve().parent
THEME_QML = APP_DIR / "qml" / "Theme.qml"
FALLBACK_QML = APP_DIR / "qml" / "Theme.fallback.qml"
# Writable copy wallust renders to when pyre is Nix-installed (the bundled
# qml/Theme.qml is a read-only Nix-store path wallust can never write).
CONFIG_THEME_QML = Path.home() / ".config" / "pyre" / "Theme.qml"


def active_theme_source() -> Path:
    """The writable config path if it exists, else the bundled repo copy."""
    return CONFIG_THEME_QML if CONFIG_THEME_QML.exists() else THEME_QML


class ThemeManager(QObject):
    """Exposes a `theme` property (a QtObject) that QML binds colors to."""

    themeChanged = Signal()

    def __init__(self):
        super().__init__()
        self._engine: QQmlEngine | None = None
        self._component = None
        self._theme: QObject | None = None
        self._watcher = QFileSystemWatcher()
        self._watcher.fileChanged.connect(self._reload)
        self._watcher.directoryChanged.connect(self._reload)
        self._reload()

    # called from main after engine exists
    def attach(self, engine: QQmlEngine):
        self._engine = engine
        self._reload()
        # Watch the bundled theme (always present) and the writable config dir
        # so we pick up ~/.config/pyre/Theme.qml the moment wallust first
        # writes it (pre-first-run the file doesn't exist yet).
        self._watcher.addPath(str(THEME_QML))
        self._watcher.addPath(str(CONFIG_THEME_QML.parent))

    def _get_theme(self) -> QObject:
        return self._theme

    theme = Property(QObject, _get_theme, notify=themeChanged)

    def _reload(self):
        if self._engine is None:
            return
        src = active_theme_source()
        if not src.exists():
            src = FALLBACK_QML
        comp = QQmlComponent(self._engine, QUrl.fromLocalFile(str(src)))
        if comp.status() != QQmlComponent.Status.Ready:
            print("ThemeManager: failed to load", src, file=sys.stderr)
            return
        new_theme = comp.create()
        if not new_theme:
            return
        # Keep the component alive: a QQmlComponent that gets garbage-collected
        # deletes the objects it created, which would leave self._theme dangling.
        self._component = comp
        if self._theme is not None:
            self._theme.deleteLater()
        self._theme = new_theme
        self.themeChanged.emit()


if __name__ == "__main__":
    print("PASS ThemeManager module import ok (needs a QML engine to run fully)")
