---
name: infernixos-rebuild
description: Use when a committed config change needs to be applied. Requests a user-approved rebuild of a pinned commit.
---

# infernixos rebuild

You cannot switch the system yourself. You request a rebuild; the user approves it from the QuickShell bar. Only the exact commit you name is built.

## Request

```
rev=$(git -C "$INFERNIXOS_CONFIG_REPO" rev-parse HEAD)
printf '%s\n%s\n' "$rev" "<one-line summary of the change>" > "$HERMES_HOME/rebuild-request.tmp"
mv "$HERMES_HOME/rebuild-request.tmp" "$HERMES_HOME/rebuild-request"
```

- Line 1: full 40-char commit hash. Anything else is ignored.
- Line 2: short human summary shown in the bar.
- Write to a temp file then `mv`, so the bar never reads a partial file.

Tell the user a rebuild is waiting in the bar: left click approves, middle click shows the diff, right click dismisses.

## After

- Check the result: `systemctl status "infernixos-rebuild@$rev"` and `journalctl -u "infernixos-rebuild@$rev"`.
- On failure: read the log, fix in the repo, commit, request again.
- Rollback is a NixOS generation: tell the user to pick the previous generation at boot or run `sudo nixos-rebuild switch --rollback`. Do not attempt it yourself.
