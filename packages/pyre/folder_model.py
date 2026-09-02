"""FolderModel — lazy directory tree for the Folders sidebar panel (PRD §6).

QAbstractItemModel over the filesystem, children loaded on expand.
Root = "/". Each node is a Path.
"""
from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import QAbstractItemModel, QModelIndex, Qt, Slot


class _Node:
    __slots__ = ("path", "parent", "children", "loaded")

    def __init__(self, path: Path, parent=None):
        self.path = path
        self.parent = parent
        self.children: list[_Node] = []
        self.loaded = False


class FolderModel(QAbstractItemModel):
    R_LABEL = Qt.UserRole + 1
    R_PATH = Qt.UserRole + 2

    def __init__(self):
        super().__init__()
        self._root = _Node(Path("/"))
        self._root.loaded = True
        self._load_children(self._root)

    def _load_children(self, node: _Node):
        try:
            entries = sorted(
                (e for e in node.path.iterdir() if e.is_dir() and not e.name.startswith(".")),
                key=lambda p: p.name.lower(),
            )
        except (PermissionError, FileNotFoundError, NotADirectoryError):
            entries = []
        node.children = [_Node(e, node) for e in entries]
        node.loaded = True

    def _node(self, index: QModelIndex) -> _Node:
        return index.internalPointer() if index.isValid() else self._root

    def _index(self, node: _Node) -> QModelIndex:
        if node is self._root or node.parent is None:
            return QModelIndex()
        row = node.parent.children.index(node)
        return self.createIndex(row, 0, node)

    # ---- QAbstractItemModel ----
    def rowCount(self, parent: QModelIndex = QModelIndex()) -> int:
        node = self._node(parent)
        if not node.loaded:
            self._load_children(node)
        return len(node.children)

    def columnCount(self, parent: QModelIndex = QModelIndex()) -> int:
        return 1

    def data(self, index: QModelIndex, role: int = Qt.DisplayRole):
        node = self._node(index)
        if role == Qt.DisplayRole or role == self.R_LABEL:
            return node.path.name or "/"
        if role == self.R_PATH:
            return str(node.path)
        return None

    def index(self, row, column, parent: QModelIndex = QModelIndex()) -> QModelIndex:
        node = self._node(parent)
        if not node.loaded:
            self._load_children(node)
        if 0 <= row < len(node.children):
            return self.createIndex(row, column, node.children[row])
        return QModelIndex()

    def parent(self, index: QModelIndex) -> QModelIndex:
        node = self._node(index)
        if node is self._root or node.parent is None:
            return QModelIndex()
        return self._index(node.parent)

    def hasChildren(self, parent: QModelIndex = QModelIndex()) -> bool:
        node = self._node(parent)
        if not node.loaded:
            self._load_children(node)
        return bool(node.children)

    def roleNames(self):
        return {self.R_LABEL: b"label", self.R_PATH: b"path"}

    # ---- nav from sidebar ----
    @Slot(str)
    def reveal(self, path: str):
        """Expand the tree to show `path`. Best-effort."""
        parts = list(Path(path).absolute().parts)  # ['/', 'home', 'user', ...]
        node = self._root
        for part in parts[1:]:
            if not node.loaded:
                self._load_children(node)
            nxt = next((c for c in node.children if c.path.name == part), None)
            if nxt is None:
                break
            node = nxt


if __name__ == "__main__":
    m = FolderModel()
    # root should have children
    assert m.rowCount() > 0, "root folder model has no children"
    # every top-level child is a dir with a path
    for r in range(min(m.rowCount(), 20)):
        idx = m.index(r, 0, QModelIndex())
        assert m.data(idx, m.R_PATH).startswith("/")
    print(f"PASS FolderModel: {m.rowCount()} top-level entries")
