"""infernixos-extensions Hermes plugin.

Read-only inventory and safe actions for the infernixos runtime: extension
registry listing, job status listing, and the build-check action. Privileged
activation is intentionally NOT exposed as a plugin tool: candidate request
and approval stay behind the infernixos CLI where approval can only come
from an authorized human, never from the conversational agent.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path


def _state_root() -> Path:
    return Path(os.environ.get("INFERNIXOS_STATE")
                or Path.home() / ".local" / "state" / "infernixos")


def _run_cli(*args: str) -> tuple[int, str]:
    env = dict(os.environ)
    env.setdefault("INFERNIXOS_STATE", str(_state_root()))
    proc = subprocess.run(
        ["infernixos", *args], capture_output=True, text=True, env=env, timeout=120
    )
    return proc.returncode, proc.stdout.strip() or proc.stderr.strip()


def register(ctx):
    def infernixos_extensions(action: str = "list", name: str = "", job_id: str = "") -> str:
        """Inspect the infernixos extension/job runtime.

        action: list | status | check | jobs
          list  - installed extensions (registry)
          status - one extension's record (name=...)
          check - run build checks on an extension source (name=...)
          jobs  - durable job list (status of each)
        Read-only/safe actions only; privileged activation is never exposed here.
        """
        if action == "list":
            code, out = _run_cli("ext", "list")
        elif action == "status":
            if not name:
                return json.dumps({"error": "status needs name="})
            code, out = _run_cli("ext", "list")
        elif action == "check":
            if not name:
                return json.dumps({"error": "check needs name="})
            code, out = _run_cli("ext", "check", name)
        elif action == "jobs":
            code, out = _run_cli("job", "list")
        else:
            return json.dumps({"error": f"unknown action: {action}"})
        try:
            data = json.loads(out)
        except json.JSONDecodeError:
            data = {"raw": out}
        data["exit_code"] = code
        return json.dumps(data, indent=2)

    ctx.register_tool(infernixos_extensions)
