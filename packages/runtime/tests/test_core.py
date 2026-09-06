from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from infernixos.state import State, StateError, safe_join
from infernixos.jobs import JobStore, JobError
from infernixos.extensions import (
    ExtensionRegistry, ExtensionSource, ExtensionBuilder, Backups,
    ExtensionError,
)
from infernixos.activation import ActivationStore, ActivationError, activation_command


def _temp_state() -> State:
    root = Path(tempfile.mkdtemp(prefix="infernixos-test-"))
    st = State(root)
    st.init(
        machine_source="github:example/machine",
        flake_target="/tmp/infernixos-flake",
        extension_workspace=str(root / "workspace"),
    )
    return st


class TestState(unittest.TestCase):
    def test_init_manifest_and_refusal(self):
        st = _temp_state()
        m = st.manifest()
        self.assertEqual(m["version"], 1)
        self.assertEqual(m["machine_source"], "github:example/machine")
        with self.assertRaises(StateError):
            st.init("a", "b", "c")

    def test_safe_join_rejects_escape(self):
        root = Path(tempfile.mkdtemp(prefix="infernixos-test-"))
        with self.assertRaises(StateError):
            safe_join(root, "..")
        with self.assertRaises(StateError):
            safe_join(root, "a/b")
        with self.assertRaises(StateError):
            safe_join(root, "/etc")
        self.assertEqual(safe_join(root, "jobs", "x"), root / "jobs" / "x")


class TestJobs(unittest.TestCase):
    def test_create_and_status(self):
        st = _temp_state()
        store = JobStore(st)
        rec = store.create("build thing", "req-1", [
            {"name": "plan", "prompt": "plan it"},
            {"name": "build", "prompt": "build it"},
        ])
        s = store.status(rec["job_id"])
        self.assertEqual(s["status"], "running")
        self.assertEqual([p["state"] for p in s["phases"]], ["pending", "pending"])
        with self.assertRaises(JobError):
            store.create("", "req", [{"name": "x", "prompt": "y"}])
        with self.assertRaises(JobError):
            store.create("n", "req", [])

    @staticmethod
    def _write_wrapper(d: Path, body: str) -> Path:
        wrapper = d / "hermes"
        wrapper.write_text(body)
        wrapper.chmod(0o755)
        return wrapper

    def test_run_with_fake_hermes_records_sessions(self):
        st = _temp_state()
        store = JobStore(st)
        rec = store.create("job", "req-1", [
            {"name": "one", "prompt": "do one"},
            {"name": "two", "prompt": "do two"},
        ])
        d = Path(tempfile.mkdtemp(prefix="bin-"))
        self._write_wrapper(d, "#!/bin/sh\nexit 0\n")
        os.environ["INFERNIXOS_HERMES_BIN"] = str(d / "hermes")
        os.environ["INFERNIXOS_TEST_USAGE"] = "1"
        try:
            done = store.run(rec["job_id"])
        finally:
            del os.environ["INFERNIXOS_HERMES_BIN"]
        self.assertEqual(done["status"], "completed")
        self.assertEqual([p["state"] for p in done["phases"]], ["done", "done"])
        with self.assertRaises(JobError):
            store.run(rec["job_id"])

    def test_run_failure_marks_failed_and_resume_reruns_only_failed(self):
        st = _temp_state()
        store = JobStore(st)
        rec = store.create("job", "req-1", [
            {"name": "one", "prompt": "p1"},
            {"name": "two", "prompt": "p2"},
        ])
        d = Path(tempfile.mkdtemp(prefix="bin-"))
        self._write_wrapper(d, "#!/bin/sh\nexit 3\n")
        os.environ["INFERNIXOS_HERMES_BIN"] = str(d / "hermes")
        try:
            with self.assertRaises(JobError):
                store.run(rec["job_id"])
        finally:
            del os.environ["INFERNIXOS_HERMES_BIN"]
        s = store.status(rec["job_id"])
        self.assertEqual(s["status"], "failed")
        self.assertEqual(s["phases"][0]["state"], "failed")
        self._write_wrapper(d, "#!/bin/sh\nexit 0\n")
        os.environ["INFERNIXOS_HERMES_BIN"] = str(d / "hermes")
        try:
            done = store.run(rec["job_id"])
        finally:
            del os.environ["INFERNIXOS_HERMES_BIN"]
        self.assertEqual(done["status"], "completed")
        self.assertEqual(done["phases"][0]["state"], "done")

    def test_missing_hermes_binary_fails_closed(self):
        st = _temp_state()
        store = JobStore(st)
        rec = store.create("job", "req", [{"name": "x", "prompt": "y"}])
        os.environ["INFERNIXOS_HERMES_BIN"] = "/nonexistent/hermes"
        try:
            with self.assertRaises(JobError):
                store.run(rec["job_id"])
        finally:
            del os.environ["INFERNIXOS_HERMES_BIN"]
        self.assertEqual(store.status(rec["job_id"])["status"], "failed")

    def test_cancel(self):
        st = _temp_state()
        store = JobStore(st)
        rec = store.create("job", "req", [{"name": "x", "prompt": "y"}])
        store.cancel(rec["job_id"])
        done = store.run(rec["job_id"])
        self.assertEqual(done["status"], "cancelled")
        self.assertEqual(done["phases"][0]["state"], "cancelled")

    def test_interrupted_run_recovers(self):
        st = _temp_state()
        store = JobStore(st)
        rec = store.create("job", "req", [{"name": "x", "prompt": "y"}])
        rec["phases"][0]["state"] = "running"
        rec["status"] = "running"
        store.save(rec["job_id"], rec)
        d = Path(tempfile.mkdtemp(prefix="bin-"))
        self._write_wrapper(d, "#!/bin/sh\nexit 0\n")
        os.environ["INFERNIXOS_HERMES_BIN"] = str(d / "hermes")
        try:
            done = store.run(rec["job_id"])
        finally:
            del os.environ["INFERNIXOS_HERMES_BIN"]
        self.assertEqual(done["status"], "completed")
        self.assertEqual(done["phases"][0]["state"], "done")


class TestExtensions(unittest.TestCase):
    def test_create_app_template_and_check(self):
        st = _temp_state()
        reg = ExtensionRegistry(st)
        src = ExtensionSource(reg)
        d = src.create("demo-app", "app", {})
        self.assertTrue((d / "package.nix").exists())
        builder = ExtensionBuilder(reg)
        self.assertEqual(builder.check(d), [])
        with self.assertRaises(ExtensionError):
            src.create("demo-app", "app", {})
        with self.assertRaises(ExtensionError):
            src.create("Bad_Name", "app", {})

    def test_install_records_ownership_and_data_dir(self):
        st = _temp_state()
        reg = ExtensionRegistry(st)
        src = ExtensionSource(reg)
        src.create("demo-app", "app", {})
        ext = reg.record(
            "demo-app", str(src.source_dir("demo-app")), "rev0",
            "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-demo-app-0.1.0",
            None, {"launcher": "demo-app"}, "req-1", "sess-1", [],
        )
        self.assertEqual(ext["source"]["path"], str(src.source_dir("demo-app")))
        self.assertTrue(Path(ext["data_dir"]).exists())
        with self.assertRaises(ExtensionError):
            reg.get("nope")

    def test_undo_restores_previous_package(self):
        st = _temp_state()
        reg = ExtensionRegistry(st)
        src = ExtensionSource(reg)
        src.create("demo-app", "app", {})
        sd = str(src.source_dir("demo-app"))
        reg.record("demo-app", sd, "rev1",
                   "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-old-0.1.0",
                   None, {"launcher": "demo-app"}, None, None)
        reg.record("demo-app", sd, "rev2",
                   "/nix/store/cccccccccccccccccccccccccccccccc-new-0.1.0",
                   None, {"launcher": "demo-app"}, None, None)
        cur = reg.get("demo-app")
        self.assertIn("cccc", cur["package"]["out"])
        prev = reg.last_accepted("demo-app", cur["updated"])
        self.assertIn("bbbb", prev["package"]["out"])

    def test_backups_roundtrip_and_unsafe_paths(self):
        st = _temp_state()
        reg = ExtensionRegistry(st)
        src = ExtensionSource(reg)
        src.create("demo-app", "app", {})
        ext = reg.record("demo-app", str(src.source_dir("demo-app")), "rev",
                         "/nix/store/dddddddddddddddddddddddddddddddddd-x", None,
                         {}, None, None)
        data = Path(ext["data_dir"])
        (data / "db").mkdir()
        (data / "db" / "data.sqlite").write_text("v1")
        b = Backups(st)
        dest = b.snapshot("demo-app", data, ["db"])
        self.assertTrue((dest / "db" / "data.sqlite").read_text() == "v1")
        (data / "db" / "data.sqlite").write_text("v2")
        b.restore("demo-app", dest.name, data)
        self.assertEqual((data / "db" / "data.sqlite").read_text(), "v1")
        with self.assertRaises(ExtensionError):
            b.snapshot("demo-app", data, ["../escape"])
        with self.assertRaises(ExtensionError):
            b.snapshot("demo-app", data, ["/etc/passwd"])

    def test_remove_keeps_data(self):
        st = _temp_state()
        reg = ExtensionRegistry(st)
        src = ExtensionSource(reg)
        src.create("demo-app", "app", {})
        ext = reg.record("demo-app", str(src.source_dir("demo-app")), "rev",
                         "/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-x", None,
                         {}, None, None)
        data = Path(ext["data_dir"])
        (data / "keep.txt").write_text("user data")
        reg.forget("demo-app")
        with self.assertRaises(ExtensionError):
            reg.get("demo-app")
        self.assertTrue((data / "keep.txt").exists())


class TestActivation(unittest.TestCase):
    GOOD = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-test-0"
    BASE = "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-base-0"

    def test_request_approve_flow_and_command(self):
        st = _temp_state()
        store = ActivationStore(st)
        rec = store.create_request("system update", self.GOOD, self.BASE)
        self.assertEqual(rec["status"], "requested")
        with self.assertRaises(ActivationError):
            store.preflight(rec)
        approved = store.verify_and_prepare(
            rec["candidate_id"], self.GOOD, self.BASE)
        self.assertEqual(approved["status"], "approved")
        self.assertEqual(approved["approved_by_uid"], os.getuid())
        cmd = activation_command(approved)
        self.assertIn(rec["candidate_id"], cmd)

    def test_approval_rejects_mismatched_closure(self):
        st = _temp_state()
        store = ActivationStore(st)
        rec = store.create_request("system update", self.GOOD, self.BASE)
        other = "/nix/store/cccccccccccccccccccccccccccccccc-other-0"
        with self.assertRaises(ActivationError):
            store.verify_and_prepare(rec["candidate_id"], other, self.BASE)

    def test_bad_closure_rejected_at_request(self):
        st = _temp_state()
        store = ActivationStore(st)
        with self.assertRaises(ActivationError):
            store.create_request("x", "/tmp/evil", self.BASE)
        with self.assertRaises(ActivationError):
            store.create_request("x", self.GOOD, "../../evil")

    def test_record_tamper_detected(self):
        st = _temp_state()
        store = ActivationStore(st)
        rec = store.create_request("t", self.GOOD, self.BASE)
        p = store.record_path(rec["candidate_id"])
        data = json.loads(p.read_text())
        data["closure"] = "/nix/store/cccccccccccccccccccccccccccccccc-evil-0"
        p.write_text(json.dumps(data))
        with self.assertRaises(ActivationError):
            store.load(rec["candidate_id"])

    def test_preflight_fails_when_base_generation_moved(self):
        st = _temp_state()
        store = ActivationStore(st)
        rec = store.create_request("t", self.GOOD, "/nix/store/dddddddddddddddddddddddddddddddd-wrong-0")
        orig = Path.resolve
        Path.resolve = lambda self, strict=False: Path("/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-current-0")
        try:
            approved = store.verify_and_prepare(rec["candidate_id"], self.GOOD, rec["expected_base_generation"])
            with self.assertRaises(ActivationError):
                store.preflight(approved)
        finally:
            Path.resolve = orig


if __name__ == "__main__":
    unittest.main(verbosity=2)
