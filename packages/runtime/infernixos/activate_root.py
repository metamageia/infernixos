"""Root-side activation helper (infernixos-activate <candidate_id>).

Must run as root via sudo/polkit by an authorized human. Re-reads and
re-verifies the immutable candidate record, runs preflight (base generation
match, approval state, digest), performs the switch, then runs the trusted
health commands from the record (which came from the state manifest, never a
request payload). On health failure rolls back to the previous generation
and marks the candidate failed. Records the phase durably BEFORE side
effects so interrupted activations are recoverable on boot.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from infernixos.state import State
from infernixos.activation import ActivationStore, ActivationError


def _current_system() -> str | None:
    link = Path("/run/current-system")
    try:
        return str(link.resolve())
    except OSError:
        return None


def main(argv: list[str]) -> int:
    if os.getuid() != 0:
        json.dump({"error": "infernixos-activate must run as root via sudo/polkit"}, sys.stdout)
        sys.stdout.write("\n")
        return 2
    if len(argv) != 1:
        json.dump({"error": "usage: infernixos-activate <candidate_id>"}, sys.stdout)
        sys.stdout.write("\n")
        return 2
    st = State()
    store = ActivationStore(st)
    try:
        rec = store.load(argv[0])
        store.preflight(rec)
    except ActivationError as exc:
        json.dump({"error": str(exc)}, sys.stdout)
        sys.stdout.write("\n")
        return 1

    previous = _current_system()
    phases_dir = st.activation_dir(rec["candidate_id"])
    (phases_dir / "phase.json").write_text(
        json.dumps({"phase": "switching", "previous": previous}) + "\n"
    )
    switch = subprocess.run(
        [str(Path(rec["closure"]) / "bin" / "switch-to-configuration"), "switch"],
        capture_output=True, text=True, timeout=600,
    )
    (phases_dir / "switch.log").write_text(switch.stdout + switch.stderr)
    if switch.returncode != 0:
        store.mark_activated(rec["candidate_id"], {"ok": False, "stage": "switch", "code": switch.returncode})
        json.dump({"error": "switch failed", "log": str(phases_dir / "switch.log")}, sys.stdout)
        sys.stdout.write("\n")
        return 1

    (phases_dir / "phase.json").write_text(
        json.dumps({"phase": "health", "previous": previous}) + "\n"
    )
    from infernixos.activation import run_activation
    result = run_activation(store, rec["candidate_id"])
    if not result.get("ok") and previous:
        rollback = subprocess.run(
            [str(Path(previous) / "bin" / "switch-to-configuration"), "switch"],
            capture_output=True, text=True, timeout=600,
        )
        result["rollback"] = {"attempted": True, "ok": rollback.returncode == 0}
        if rollback.returncode == 0:
            store.mark_activated(rec["candidate_id"], {**result, "ok": False, "rolled_back": True})
    if not result.get("ok"):
        json.dump(result, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 1
    gcdir = st.root / "gc-root"
    gcdir.mkdir(parents=True, exist_ok=True)
    if previous:
        subprocess.run(["nix-store", "--add-root", str(gcdir / f"{rec['candidate_id']}-previous"),
                        "--realise", previous],
                       capture_output=True, text=True)
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
