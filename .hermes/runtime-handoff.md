# infernixos runtime-handoff - actual CLI/API as implemented.
# Nix worker: wire packages/runtime/package.nix into flake + modules.

## Package
- packages/runtime/package.nix -> pname infernixos-runtime, two executables:
  - bin/infernixos (user CLI; python -B -m infernixos; PATH gets nix+git)
  - bin/infernixos-activate (ROOT helper; run via sudo/polkit by an
    authorized human; refuses non-root; takes ONLY a candidate id)
- Build verified: nix build --no-link --print-out-paths --impure --expr
  'let pkgs = import <nixpkgs> {}; in pkgs.callPackage ./packages/runtime/package.nix {}'
  -> /nix/store/qvp2z54h6abl60x617x300wnrrpvx2xy-infernixos-runtime-0.1.0

## State root
- Dir: $INFERNIXOS_STATE (recommended per-user ~/.local/state/infernixos).
  Subdirs: jobs/ extensions/ backups/ activations/ locks/. manifest.json
  written by init.

## CLI (all output JSON on stdout, exit != 0 on error)
infernixos init --machine-source URL --flake-target TARGET --workspace DIR
  [--health-cmd CMD]... [--force]
  - One-time; refuses re-init without --force. flake-target is the machine
    flake the extension builder builds against. health-cmd entries are the
    ONLY commands the root activation path will ever run.
infernixos ownership
  - Machine-readable ownership manifest for Hermes: {version, runtime,
    machine_source, flake_target, extension_workspace, health_commands,
    state_root, commands:{job,extension,activation}}
infernixos job create --name N --request-id R --phase NAME "PROMPT" [--phase ...]
infernixos job run|resume JOB_ID (identical; resume is alias)
infernixos job status JOB_ID
infernixos job cancel JOB_ID
infernixos job list
  - Each phase runs: hermes -z --usage-file <job>/usage/<phase>.json PROMPT
    in the FOREGROUND (no background inference). session_id from the usage
    file is recorded in the durable job record; resume after interruption
    reruns only pending/failed phases; completed job rerun refused.
  - Override binary: env INFERNIXOS_HERMES_BIN (default `hermes` in PATH).
infernixos ext create NAME app|widget|hermes-plugin
  - Scaffolds git-tracked source in <workspace>/<name> (initial commit).
infernixos ext check NAME (real checks: manifest, files, unsafe paths)
infernixos ext build NAME (nix build -f <flake-target> <src>/package.nix)
infernixos ext install NAME [--request-id R] [--session-id S]
  - checks must pass; records source rev + package out + entry + permissions
    in extensions/registry.json; seeds extensions/<name>/data dir;
    writes extensions/<name>/install.json; hermes-plugin kind symlinks
    extensions/<name>/plugin -> source dir.
infernixos ext update NAME [--message M]
infernixos ext undo NAME (restore previous accepted package record)
infernixos ext remove NAME (backup data, forget registry+install artifacts,
  keep source AND data - never auto-delete data)
infernixos ext list | disable NAME | enable NAME
infernixos ext set-entry NAME '<json>' | set-permissions NAME --permission P...
infernixos ext data-backup NAME --paths '["rel/path", ...]'
infernixos ext data-restore NAME STAMP
  - backups under <state>/backups/<name>/<stamp>/; absolute or ..
    containing paths rejected (fail closed).

## Privileged activation (agent Nix is root-equivalent -> human only)
infernixos activate request --label L --closure /nix/store/... --expected-base /nix/store/...
  - agent builds candidate UNPRIVILEGED, then records it. Store paths only.
infernixos activate approve CANDIDATE_ID --closure ... --expected-base ...
  - human/authorized-helper step; re-verifies exact closure+base against the
    immutable record (digest tamper detection), records approving uid, prints
    the exact command: sudo infernixos-activate CANDIDATE_ID
  - agent can NEVER self-approve: approval uid + record digest are written
    only through this command; no CLI flag asserts consent.
infernixos-activate CANDIDATE_ID (as root)
  - re-verifies record (approval status, digest, closure exists, current
    /run/current-system == expected base), writes phase.json BEFORE
    switching, runs closure/bin/switch-to-configuration switch, then runs
    ONLY the health commands from the state manifest (never request
    payloads, timeout 120s each). Health failure -> automatic rollback to
    previous generation + candidate marked failed. Previous closure pinned
    via gc-root under state.
infernixos activate status ID | list
- Recovery on boot: activations/<id>/phase.json with phase switching/health
  means the operation was interrupted; health/rollback can be re-run safely
  because the previous generation is pinned in <state>/gc-root.

## Registry/install record shapes (for HM module + QuickShell + plugin)
extensions/registry.json:
  {"version":1,"extensions":{"<name>":{source:{path,rev},package:{out,drv},
   entry:{...},data_dir,permissions:[...],request_id,session_id,updated,
   history:[...],disabled?}}}
extensions/<name>/install.json: {name,package_out,source_rev,kind,entry}
  kind: app | widget | hermes-plugin
  app entry: {"launcher": "<bin-name>"}
  widget entry: {"qml": "widget.qml"}
  hermes-plugin entry: {"plugin_dir": "<name>"}

## Wiring points wanted from Nix worker
1. flake perSystem packages: runtime = callPackage ./packages/runtime/package.nix {}
2. HM module: infernixos.desktop.runtime = { enable; }
   - home.packages += runtime package
   - activation script (only if absent, picker-state pattern):
     infernixos init --machine-source <consumer sets> --flake-target <self>
       --workspace ~/.local/share/infernixos/extensions
       --health-cmd "systemctl is-system-running" ...
3. NixOS module: polkit/wheel guard so ONLY real human wheel members can run
   infernixos-activate; hermes user must NOT be in wheel.
4. QuickShell: extensions/registry.json + install.json are read directly
   by the extension loader QML (see homeManagerModules/quickshell-config).

## Not yet implemented (do not wire yet)
- bin/infernixos-ask (Ask Hermes dialog) - planned
- QuickShell extension-loader.qml - in progress
- Hermes UI plugin (~/.hermes/plugins/infernixos-extensions/) - planned
- Shipped example extension + skill - planned
