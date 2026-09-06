"""End-to-end CLI tests: exercise the entry point as a real subprocess."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = [sys.executable, "-B", "-m", "infernixos"]


def run(args: list[str], env_extra: dict) -> tuple[int, dict]:
    env = dict(os.environ)
    env.update(env_extra)
    env["PYTHONPATH"] = str(ROOT)
    proc = subprocess.run(CLI + args, capture_output=True, text=True, env=env)
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        data = {"_raw": proc.stdout, "_stderr": proc.stderr}
    return proc.returncode, data


class TestCLI(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="infernixos-cli-"))
        self.env = {
            "INFERNIXOS_STATE": str(self.tmp / "state"),
        }

    def test_init_ownership_job_extension_activation(self):
        ws = self.tmp / "workspace"
        code, out = run(["init", "--machine-source", "github:x/m", "--flake-target", "/tmp/flake", "--workspace", str(ws)], self.env)
        self.assertEqual(code, 0, out)

        code, out = run(["ownership"], self.env)
        self.assertEqual(code, 0, out)
        self.assertEqual(out["machine_source"], "github:x/m")
        self.assertEqual(out["extension_workspace"], str(ws))
        self.assertIn("infernixos job", out["commands"]["job"])

        code, out = run(["job", "create", "--name", "demo", "--request-id", "r1", "--phase", "p1", "say hi"], self.env)
        self.assertEqual(code, 0, out)
        job_id = out["job_id"]

        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        hermes = bin_dir / "hermes"
        hermes.write_text("#!/bin/sh\nexit 0\n")
        hermes.chmod(0o755)
        code, out = run(["job", "run", job_id], {**self.env, "INFERNIXOS_HERMES_BIN": str(hermes)})
        self.assertEqual(code, 0, out)
        self.assertEqual(out["status"], "completed")

        code, out = run(["ext", "create", "demo-app", "app"], self.env)
        self.assertEqual(code, 0, out)
        src = Path(out["source"])
        self.assertTrue((src / "package.nix").exists())

        code, out = run(["ext", "check", "demo-app"], self.env)
        self.assertEqual(code, 0, out)
        self.assertTrue(out["ok"], out)

        nix = bin_dir / "nix"
        fake_out = self.tmp / "store" / "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-demo"
        fake_out.mkdir(parents=True)
        nix.write_text("#!/bin/sh\necho " + str(fake_out) + "\n")
        nix.chmod(0o755)
        code, out = run(["ext", "install", "demo-app", "--request-id", "r2"], {**self.env, "PATH": f"{bin_dir}:{os.environ['PATH']}"})
        self.assertEqual(code, 0, out)
        install = json.loads((self.tmp / "state" / "extensions" / "demo-app" / "install.json").read_text())
        self.assertEqual(install["kind"], "app")

        code, out = run(["ext", "list"], self.env)
        self.assertEqual(code, 0, out)
        self.assertIn("demo-app", out["extensions"])

        code, out = run(["ext", "data-backup", "demo-app", "--paths", "[\"db.sqlite\"]"], self.env)
        self.assertEqual(code, 0, out)

        code, out = run(["ext", "disable", "demo-app"], self.env)
        self.assertEqual(code, 0, out)
        self.assertTrue(out["disabled"])

        code, out = run(["activate", "request", "--label", "sys", "--closure", "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-c-0", "--expected-base", "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-b-0"], self.env)
        self.assertEqual(code, 0, out)
        cid = out["candidate_id"]
        code, out = run(["activate", "approve", cid, "--closure", "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-c-0", "--expected-base", "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-b-0"], self.env)
        self.assertEqual(code, 0, out)
        self.assertIn(cid, out["activation_command"])

        code, out = run(["activate", "approve", cid, "--closure", "/nix/store/cccccccccccccccccccccccccccccccc-c-0", "--expected-base", "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-b-0"], self.env)
        self.assertNotEqual(code, 0)

    def test_second_init_refused(self):
        code, out = run(["init", "--machine-source", "a", "--flake-target", "b", "--workspace", str(self.tmp / "w")], self.env)
        self.assertEqual(code, 0)
        code, out = run(["init", "--machine-source", "a", "--flake-target", "b", "--workspace", str(self.tmp / "w")], self.env)
        self.assertNotEqual(code, 0)
        self.assertIn("error", out)


if __name__ == "__main__":
    unittest.main()
