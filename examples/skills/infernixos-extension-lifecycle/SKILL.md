---
name: infernixos-extension-lifecycle
description: Create, adapt, check, build and install infernixos extensions and system change candidates via the infernixos runtime CLI. Use when a Hermes request asks to build/install/modify a desktop widget, app, or Hermes plugin on HermetixOS.
---

# infernixos extension lifecycle

Read the machine-readable ownership manifest first; it tells you where
source, state, and commands live:

    infernixos ownership

## Creating and shipping a capability

1. Scaffold versioned source (never edit store paths):

       infernixos ext create <name> app|widget|hermes-plugin

   Source lands in the extension workspace under <name>/ as a git repo.
   Edit the files there: app = main.py + package.nix + manifest.json,
   widget = widget.qml, hermes-plugin = plugin.yaml + __init__.py with
   register(ctx).

2. Before any build, run the real checks and fix every problem:

       infernixos ext check <name>

3. Build the immutable package (unprivileged; do not request root):

       infernixos ext build <name>

4. Install (records source rev, package out path, entry point, permissions
   and the request/session linkage in the registry):

       infernixos ext install <name> --request-id <id> --session-id <id>

5. To revise: edit source, then `infernixos ext update <name>`. To revert to
   the previous accepted package: `infernixos ext undo <name>`.

## Rules

- Completion means `ext check` passes and `ext install` succeeded, not that
  a model turn ended.
- Data lives in the extension's data dir and is never auto-deleted;
  `ext remove` keeps source and data. Snapshot data with
  `ext data-backup` before risky updates; restore with `ext data-restore`.
- Widget changes appear live in the QuickShell bar process after install or
  undo (the loader watches the registry). Invalid extensions fail
  independently; do not restart the shell to fix one.
- Privileged system activation: build the closure unprivileged, then
  `infernixos activate request`. NEVER attempt to approve a candidate
  yourself; approval requires the human to run the printed
  `sudo infernixos-activate <id>` command. Do not pass `--force`-style
  consent flags or assert user consent in any way.
- Long work goes through durable jobs so it survives restarts:

      infernixos job create --name build-thing --request-id <id> \
        --phase plan "..." --phase implement "..."
      infernixos job run <job_id>       # or `resume`; rerun is safe

  Job phases run real `hermes -z` in the foreground; never spawn
  background inference from plugin code.
