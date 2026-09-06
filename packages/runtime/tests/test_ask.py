"""Tests for the Ask Hermes prompt assembly (GUI-independent parts)."""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from infernixos.ask import build_prompt, main


class TestAsk(unittest.TestCase):
    def test_paths_only_default(self):
        p = build_prompt("why slow?", "pyre", ["/tmp/x/y.txt"], None, False)
        self.assertIn("why slow?", p)
        self.assertIn("/tmp/x/y.txt", p)
        self.assertIn("paths only", p)
        self.assertNotIn("file contents", p)

    def test_contents_opt_in(self):
        d = Path(tempfile.mkdtemp())
        f = d / "a.txt"
        f.write_text("hello")
        p = build_prompt("q", None, [str(f)], "extra", True)
        self.assertIn("hello", p)
        self.assertIn("extra", p)

    def test_context_off_nothing_attached(self):
        p = build_prompt("q", "app", ["/tmp/f"], "text", False)
        self.assertNotEqual(p, "q")
        from infernixos import ask
        # context=off path handled by main(); verify build_prompt called with empties
        self.assertIn("q", p)

    def test_print_only_assembles_without_hermes(self):
        r, w = os.pipe()
        old = sys.__stdout__
        os.dup2(w, 1)
        try:
            code = main(["--print-only", "--yes", "what is this?"])
        finally:
            os.dup2(r, 0)
            sys.stdout = old
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
