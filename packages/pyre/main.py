"""pyre — near-1:1 Dolphin file manager in PySide6 + QML.

No compile step: Python runtime + interpreted QML.
"""
import sys
from pathlib import Path

from PySide6.QtCore import QUrl, Qt, QSize
from PySide6.QtGui import QColor, QGuiApplication, QIcon, QPainter, QPalette, QPixmap
from PySide6.QtQml import QQmlApplicationEngine, QQmlEngine
from PySide6.QtQuick import QQuickImageProvider

from core import FileController
from folder_model import FolderModel
from places_model import PlacesModel
from search_model import SearchModel
from settings import Settings
from theme import ThemeManager

APP_DIR = Path(__file__).resolve().parent


class ThemeIconProvider(QQuickImageProvider):
    """Serves image://theme/<name> by rendering the named themed icon.

    QML's icon.name / IconImage resolution proved unreliable under this
    PySide6+NixOS stack, so we route icon lookups through QIcon.fromTheme,
    which we've verified resolves Breeze.

    Icons are TINTED to the theme so they match the rice: folders get the
    accent color, everything else the foreground (light text). Only GENERIC
    icons route here — real content (image thumbnails, video posters, preview
    files) goes through file paths (thumbUrl / previewImageUriProp), never
    image://theme, so it stays true-color.
    """

    def __init__(self):
        super().__init__(QQuickImageProvider.ImageType.Pixmap)
        self._fg = QColor("#E5E5E5")
        self._accent = QColor("#61AEE9")

    def set_colors(self, fg, accent):
        """Plain QColors (no QObject ref) fed from ThemeManager on reload."""
        self._fg = QColor(fg)
        self._accent = QColor(accent)

    def requestPixmap(self, id_: str, size: QSize, requestedSize: QSize) -> QPixmap:
        accent = False
        if "?" in id_:
            name, _, q = id_.partition("?")
            accent = (q == "accent")
        else:
            name = id_.split("/")[0]
        icon = QIcon.fromTheme(name) if name else QIcon()
        s = requestedSize if requestedSize.isValid() else QSize(64, 64)
        if icon.isNull():
            p = QPixmap(s)
            p.fill(Qt.GlobalColor.transparent)
            return p
        src = icon.pixmap(s)
        out = QPixmap(s)
        out.fill(Qt.GlobalColor.transparent)
        painter = QPainter(out)
        painter.drawPixmap(0, 0, src)
        # SourceIn keeps the icon's alpha (shape/antialiasing), replaces color.
        painter.setCompositionMode(QPainter.CompositionMode_SourceIn)
        painter.fillRect(out.rect(), self._accent if (name == "folder" or accent) else self._fg)
        painter.end()
        return out


def apply_palette(theme_obj):
    """Theme all default QtQuick Controls (menu bar, text fields, sliders,
    toolbuttons) via the app QPalette. Called on theme load + every live
    reload so the whole app tracks the wallpaper, not just explicit th.* binds.
    """
    if theme_obj is None:
        return

    def C(name):
        v = theme_obj.property(name)
        return QColor(v) if v else QColor()

    bg, fg, accent = C("bg"), C("fg"), C("accent")
    sel, selfg = C("selection"), C("selectionFg")
    border = C("border")
    pal = QPalette()
    pal.setColor(QPalette.Window, bg)
    pal.setColor(QPalette.WindowText, fg)
    pal.setColor(QPalette.Base, bg)
    pal.setColor(QPalette.AlternateBase, bg)
    pal.setColor(QPalette.Text, fg)
    pal.setColor(QPalette.PlaceholderText, border)
    pal.setColor(QPalette.Button, bg)
    pal.setColor(QPalette.ButtonText, fg)
    pal.setColor(QPalette.Highlight, accent)
    pal.setColor(QPalette.HighlightedText, selfg)
    pal.setColor(QPalette.Link, accent)
    QGuiApplication.setPalette(pal)


def main() -> int:
    app = QGuiApplication(sys.argv)
    app.setApplicationName("pyre")
    app.setOrganizationName("pyre")
    # Breeze is wired in via XDG_DATA_DIRS (flake/package). Resolve icon.name
    # lookups against it instead of leaving the theme empty.
    import os
    icon_dirs = [
        os.path.join(d, "icons")
        for d in os.environ.get("XDG_DATA_DIRS", "").split(":")
        if d
    ]
    if icon_dirs:
        QIcon.setThemeSearchPaths(icon_dirs)
    QIcon.setThemeName("breeze")

    engine = QQmlApplicationEngine()

    settings = Settings()
    controller = FileController(settings)
    controller.restore_session()
    folder_model = FolderModel()
    places_model = PlacesModel(settings.places)
    search_model = SearchModel()
    theme = ThemeManager()

    for name, obj in {
            "controller": controller,
            "fsModel": controller.model,
            "splitModel": controller.splitModel,
            "settings": settings,
            "folderModel": folder_model,
            "placesModel": places_model,
            "searchModel": search_model,
            "theme": theme,
        }.items():
        engine.rootContext().setContextProperty(name, obj)

    theme.attach(engine)

    # image://theme/<name> -> Breeze icon, tinted to theme (ThemeIconProvider).
    # Colors fed via themeChanged so a live theme reload recolors icons too.
    provider = ThemeIconProvider()
    def sync_theme():
        t = theme.theme
        if t is not None:
            provider.set_colors(t.property("fg"), t.property("accent"))
            apply_palette(t)
    theme.themeChanged.connect(sync_theme)
    sync_theme()
    engine.addImageProvider("theme", provider)

    qml = APP_DIR / "qml" / "main.qml"
    engine.load(QUrl.fromLocalFile(str(qml)))
    if not engine.rootObjects():
        print("FATAL: failed to load root QML", file=sys.stderr)
        return 1

    rc = app.exec()
    controller.save_session()
    settings.save()
    return rc


if __name__ == "__main__":
    sys.exit(main())
