---
name: infernixos-theme-app
description: Use when making an app follow the infernixos wallust theme. Adds a wallust template via the user's config repo.
---

# infernixos theme an app

infernixos colors come from wallust. Each wallpaper change re-renders every template.

## Steps

1. Find the app's color config file and whether it live-reloads.
2. Write a wallust template using `{{background}}`, `{{foreground}}`, `{{color0}}`..`{{color15}}`, placed in `$INFERNIXOS_CONFIG_REPO`.
3. Register it as a wallust template target (template file + target path) in the user's home-manager config.
4. If the app does not live-reload, note the reload command for the user.
5. Commit, then use `infernixos-rebuild`.

Never write the rendered file by hand; wallust owns it.
