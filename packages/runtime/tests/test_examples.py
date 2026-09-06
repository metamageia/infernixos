"""Tests for shipped examples and the Hermes UI plugin surface."""
from __future__ import annotations

import ast
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent.parent


class TestExamples(unittest.TestCase):
    def test_example_extension_files(self):
        d = REPO / "examples" / "extensions" / "hello-clock"
        m = json.loads((d / "manifest.json").read_text())
        self.assertEqual(m["name"], "hello-clock")
        self.assertEqual(m["kind"], "app")
        self.assertEqual(m["entry"]["launcher"], "hello-clock")
        self.assertTrue((d / "package.nix").exists())
        self.assertTrue((d / "main.py").exists())
        ast.parse((d / "main.py").read_text())

    def test_skill_and_plugin_examples(self):
        skill = REPO / "examples" / "skills" / "infernixos-extension-lifecycle" / "SKILL.md"
        self.assertIn("infernixos ext create", skill.read_text())
        self.assertIn("activate request", skill.read_text())
        self.assertIn("NEVER attempt to approve", skill.read_text())
        plug = REPO / "examples" / "plugins" / "infernixos-extensions"
        manifest = (plug / "plugin.yaml").read_text()
        self.assertIn("name: infernixos-extensions", manifest)
        src = (plug / "__init__.py").read_text()
        ast.parse(src)
        self.assertIn("def register(ctx)", src)
        self.assertIn("ctx.register_tool", src)
        self.assertNotIn("activate approve", src)


class TestPluginFunction(unittest.TestCase):
    def test_register_exposes_tool_and_safe_actions(self):
        sys.path.insert(0, str(REPO / "examples" / "plugins" / "infernixos-extensions"))
        import __init__ as plugin

        captured = {}

        class Ctx:
            def register_tool(self, fn):
                captured["fn"] = fn

        plugin.register(Ctx())
        self.assertIn("fn", captured)
        out = captured["fn"]("bogus-action")
        self.assertIn("unknown action", out)


if __name__ == "__main__":
    unittest.main()
