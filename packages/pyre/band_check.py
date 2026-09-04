#!/usr/bin/env python3
"""Minimal check for the marquee band logic (fs_model.rows_in_rect + set_band).

The deleted ~/Development/pyre repo carried the QML test harness; the vendored
package has none. This asserts the geometry maths + live band replacement that
the FileView.qml marquee depends on.
"""
import os, sys, tempfile
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from fs_model import FileSystemModel

tmp = tempfile.mkdtemp()
for i in range(8):
    (Path(tmp) / f"f{i}.txt").write_text("")

m = FileSystemModel(Path(tmp))
m.reload()
assert m.rowCount() == 8, m.rowCount()

# 2 columns x 4 rows, cell 100x100, viewport 900x700 (matches QML default).
# Band over (0,0)-(199,199) = cells row0 (indices 0,1) + row1 (2,3).
got = m.rows_in_rect(0, 0, 200, 200, 100.0, 100.0, 2, 0.0, 0.0)
assert got == [0, 1, 2, 3], got
# colCount derivation used by QML: floor(viewport/cellWidth)
cols = max(1, int(900 / 76.0))
assert cols == 11, cols

# scrolled viewport: oy=100 moves the band into physical row 1 (col 0 only
# at 100px width over 100px cells)
got = m.rows_in_rect(0, 0, 100, 100, 100.0, 100.0, 2, 0.0, 100.0)
assert got == [2], got

# set_band replaces selection (live rubber-band), and empty band clears
m.set_band([0, 1, 2, 3])
assert m.selectedRows == [0, 1, 2, 3], m.selectedRows
m.set_band([5])
assert m.selectedRows == [5], m.selectedRows
m.set_band([])
assert m.selectedRows == [], m.selectedRows

print("band logic OK")
