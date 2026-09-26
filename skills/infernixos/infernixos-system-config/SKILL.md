---
name: infernixos-system-config
description: Use when changing the NixOS system or home config on infernixos. Edits and commits in the user's config repo.
---

# infernixos system config

The user's machine config is a git flake repo at `$INFERNIXOS_CONFIG_REPO`. It is the single source of truth: every change goes there, as a commit, so the user can push it and carry it to a new machine.

## Rules

- Edit only inside `$INFERNIXOS_CONFIG_REPO`. Never edit `/etc`, `~/.config` files owned by home-manager, or the infernixos distro input.
- Prefer existing `infernixos.*` options before adding raw NixOS or home-manager config.
- One logical change per commit. Commit message states what and why.
- Never rebuild directly. Request a rebuild with the `infernixos-rebuild` skill.

## Steps

1. `git -C "$INFERNIXOS_CONFIG_REPO" status` — stop and ask if the tree is dirty with changes you did not make.
2. Read the relevant modules before editing.
3. Edit.
4. Evaluate without switching:
   `nix build --dry-run "$INFERNIXOS_CONFIG_REPO#nixosConfigurations.$(hostname).config.system.build.toplevel"`
5. Commit: `git -C "$INFERNIXOS_CONFIG_REPO" add -A && git -C "$INFERNIXOS_CONFIG_REPO" commit -m "<message>"`
6. Hand off to `infernixos-rebuild`.
