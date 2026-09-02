"""PlacesModel — the Places sidebar panel (PRD §6). Wraps settings.places."""
from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import QAbstractListModel, QModelIndex, Qt


class PlacesModel(QAbstractListModel):
    R_LABEL = Qt.UserRole + 1
    R_PATH = Qt.UserRole + 2
    R_ICON = Qt.UserRole + 3

    # label -> Breeze icon name
    _ICONS = {
        "Home": "user-home",
        "Desktop": "user-desktop",
        "Documents": "folder-documents",
        "Downloads": "folder-downloads",
        "Pictures": "folder-pictures",
        "Music": "folder-music",
        "Videos": "folder-videos",
        "Root": "drive-harddisk",
    }

    def __init__(self, places):
        super().__init__()
        self._places = places

    def rowCount(self, parent: QModelIndex = QModelIndex()) -> int:
        return 0 if parent.isValid() else len(self._places)

    def data(self, index: QModelIndex, role: int = Qt.DisplayRole):
        if not index.isValid() or not (0 <= index.row() < len(self._places)):
            return None
        p = self._places[index.row()]
        if role == Qt.DisplayRole or role == self.R_LABEL:
            return p["label"]
        if role == self.R_PATH:
            return str(Path(p["path"]).expanduser())
        if role == self.R_ICON:
            return self._ICONS.get(p["label"], "folder")
        return None

    def roleNames(self):
        return {self.R_LABEL: b"label", self.R_PATH: b"path", self.R_ICON: b"iconName"}

    def add_place(self, label: str, path: str):
        self.beginInsertRows(QModelIndex(), len(self._places), len(self._places))
        self._places.append({"label": label, "path": path})
        self.endInsertRows()

    def remove_place(self, row: int):
        if 0 <= row < len(self._places):
            self.beginRemoveRows(QModelIndex(), row, row)
            del self._places[row]
            self.endRemoveRows()


if __name__ == "__main__":
    from settings import Settings
    s = Settings()
    m = PlacesModel(s.places)
    assert m.rowCount() >= 8
    assert m.data(m.index(0), m.R_PATH) == str(Path.home())
    print(f"PASS PlacesModel: {m.rowCount()} places")
