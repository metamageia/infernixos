#!/usr/bin/env python3
"""Minimal QML load check: build the same context as main() and verify
main.qml (including the Open-With dialog) loads without errors.

Run:  QT_QPA_PLATFORM=offscreen nix-shell -p "python3.withPackages (ps: [ ps.pyside6 ])" \
        -p qt6.qtdeclarative -p qt6.qtsvg --run "python3 qml_load_check.py"
"""
import os
import sys
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, str(Path(__file__).parent))

from PySide6.QtCore import QUrl  # noqa: E402
from PySide6.QtGui import QGuiApplication  # noqa: E402
from PySide6.QtQml import QQmlApplicationEngine  # noqa: E402

from core import FileController  # noqa: E402
from folder_model import FolderModel  # noqa: E402
from main import ThemeIconProvider  # noqa: E402
from places_model import PlacesModel  # noqa: E402
from search_model import SearchModel  # noqa: E402
from settings import Settings  # noqa: E402
from terminal_session import TerminalSession  # noqa: E402
from theme import ThemeManager  # noqa: E402

app = QGuiApplication(sys.argv)
settings = Settings()
controller = FileController(settings)
theme = ThemeManager()

engine = QQmlApplicationEngine()
for name, obj in {
    "controller": controller,
    "fsModel": controller.model,
    "splitModel": controller.splitModel,
    "settings": settings,
    "folderModel": FolderModel(),
    "placesModel": PlacesModel(settings.places),
    "searchModel": SearchModel(),
    "terminal": TerminalSession(),
    "theme": theme,
}.items():
    engine.rootContext().setContextProperty(name, obj)
theme.attach(engine)
engine.addImageProvider("theme", ThemeIconProvider())

engine.warnings.connect(lambda warnings: print("QML WARN:", warnings))

engine.load(QUrl.fromLocalFile(str(Path(__file__).parent / "qml" / "main.qml")))
ok = bool(engine.rootObjects())
print("root objects:", len(engine.rootObjects()))
print("QML LOAD " + ("OK" if ok else "FAILED"))
sys.exit(0 if ok else 1)
