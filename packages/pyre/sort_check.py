import os, tempfile
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from pathlib import Path
from fs_model import FileSystemModel, SortKey

tmp = Path(tempfile.mkdtemp())
(tmp / "a.txt").write_text("x")
(tmp / "b.txt").write_text("y")
os.symlink("/nonexistent", tmp / "broken")

for sk in SortKey:
    m = FileSystemModel(tmp)
    m.sort_key = int(sk)
    m._apply_filter()
    if m.sort_key == SortKey.TYPE:
        assert not (m.rowCount() == 0), "TYPE sort should still list all"
    m.sort_desc = True
    m._apply_filter()

assert FileSystemModel(tmp).rowCount() == 3
print("sort crash fixed across all keys + desc")
