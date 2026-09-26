---
name: infernixos-quickshell-widget
description: Use when building or changing a QuickShell bar widget on infernixos. Ships it declaratively via the user's config repo.
---

# infernixos QuickShell widget

The infernixos bar is one QuickShell process. Widgets are QML.

## Rules

- Widget source lives in `$INFERNIXOS_CONFIG_REPO` (for example `widgets/<name>.qml`), never only in `~/.config`, so it survives a move to a new machine.
- Use the bar palette properties (`root.barAccent`, `root.barMuted`, `root.barFg`, `root.barBg`) and `root.uiFont`. No hex literals: wallust recolors live.
- Shell out with `Process` + `StdioCollector`; poll with `Timer`; watch files with `FileView { watchChanges: true }`. Never block the UI thread.
- Set `Accessible.name` on anything clickable.

## Steps

1. Prototype: `quickshell -p <file.qml>` and check the output for QML errors.
2. Add the file to the config repo and wire it through home-manager.
3. Commit, then use `infernixos-rebuild`.
