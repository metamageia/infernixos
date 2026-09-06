# Wallust dynamic theming — self-contained home-manager module.
#
# WHAT IT DOES
#   - Installs `wallust` (v3.5.x) and `awww` (the animated Wayland wallpaper
#     daemon; niri has NO native wallpaper-image support). awww gives smooth
#     fade/wipe/grow transitions between wallpapers — no screen flash.
#   - Ships ~/.config/wallust/wallust.toml + its `templates/` dir. wallust reads
#     colors from a chosen wallpaper and renders templates for fuzzel,
#     kitty, and niri.
#   - Ships `wallust-switch`: a fuzzel-dmenu launcher that lists wallpapers from
#     the repo wallpapers dir, applies the chosen one with `wallust run ...`, and
#     sets it as the live desktop background with `awww img --transition-type fade`.
#
# VERIFIED EMPIRICALLY (nix shell nixpkgs#wallust, run against the warframe wp):
#   CLI:  wallust run --config-dir <DIR> <IMAGE>      # image is a POSITIONAL arg
#   Resolving placeholders: color0..color15, background, foreground, cursor, alpha
#   (alpha defaults to 100).  `accent` and `wallpaper` DO NOT resolve (empty) — so
#   templates use {{background}}/{{colorN}}, never {{accent}}/{{wallpaper}}.
#   Templates live in a `templates/` subdir of the config dir; `target` is the
#   absolute runtime path wallust writes.
#
# CONFIG-OWNERSHIP STRATEGY (wallust owns colors; HM keeps structure)
#   - fuzzel: HM writes fuzzel.ini ONLY when settings != {} (it is empty here), so no
#     conflict — wallust writes ~/.config/fuzzel/fuzzel.ini directly. HM still provides
#     the fuzzel package + deps (jq/wl-clipboard/xdg-utils/coreutils) via modules/fuzzel.
#   - kitty: HM writes kitty.conf ONLY when settings != {} (empty), so wallust
#     writes ~/.config/kitty/kitty.conf directly (picked up on next launch).
#   - niri: the nixpkgs home-manager `wayland.windowManager.niri` module writes
#     ~/.config/niri/config.kdl from `settings` via the NAMED entry
#     `xdg.configFile."niri/config.kdl"`. niri 26.04 DOES support `include`
#     directives, so we append `include optional=true "colors.kdl"` (colors.kdl
#     is wallust-generated from niri.tmpl) by using the module's own
#     `extraConfig` hook — NOT a fresh xdg.configFile target (that collides).
#     All binds/window-rules/gaps survive via `settings`; the include is added
#     at the END of the generated config. Enabled (Phase 1b).
#
# NIRI RUNTIME NOTE (honest limitation)
#   niri reads config.kdl only at session (compositor) start; there is no live reload
#   IPC. So wallust regenerating niri/colors.kdl takes visual effect on niri after the
#   NEXT login / niri restart — NOT immediately. The switcher therefore does NOT kill
#   niri (that would end the session). fuzzel/kitty pick up their new files
#   live (fuzzel/kitty on next launch). `include optional=true`
#   keeps a missing colors.kdl (pre-first-run) from breaking niri startup.
#
# KEYBIND (recommended — add to modules/niri/home.nix `binds`, out of scope here)
#   "Mod+W".action.spawn = "wallust-switch";
{
  config,
  pkgs,
  lib,
  ...
}: let
    # Wallpapers source: infernixos defaults + consumer's own dirs (merged
    # list, each a read-only store path). Scanned by the fuzzel menu below.
  wallpaperDirs = config.infernixos.desktop.theming.wallpaper.dirs;

  # Hermes desktop skin dir (defaults to the gateway's skins dir).
  hermesSkinsDir = config.infernixos.desktop.theming.hermesSkinsDir;

  # Zen profile chrome dir (on-disk hash varies per machine).
  zenProfileDir = config.infernixos.desktop.theming.zenProfileDir;

  wallustCfgDir = "${config.xdg.configHome}/wallust";

  # Applies a chosen wallpaper: wallust run + awww img + persist last-wallpaper.
  # Shared by the fuzzel menu (wallust-switch) and the QuickShell diamond picker
  # (Phase 6). Takes the wallpaper path as $1.
  wallust-apply = pkgs.writeShellScriptBin "wallust-apply" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail
    wp="$1"
    CONFIG_DIR="${wallustCfgDir}"

    [ -n "$wp" ] || exit 0
    [ -f "$wp" ] || { echo "wallust-apply: not a file: $wp" >&2; exit 1; }


    # Ensure the Zen chrome dir exists too — the zen.tmpl target lives at
    # <profile>/chrome/userChrome.css, which wallust won't create for us.
    mkdir -p "${config.xdg.configHome}/zen/${zenProfileDir}/chrome"

    # Ensure the Pyre config dir exists — wallust doesn't create parent dirs of a
    # template target, and theme.py reads Theme.qml from here at launch.
    mkdir -p "${config.xdg.configHome}/pyre"

    # Re-theme: apply palette + render all templates (fuzzel/kitty).
    ${pkgs.wallust}/bin/wallust run --config-dir "$CONFIG_DIR" "$wp"

    # Hermes desktop live-retheme: the gateway's skin watcher polls
    # (active skin name, skins/<name>.yaml mtime) and broadcasts skin.changed
    # on any move, but the desktop's apply guard (backend-sync.ts) is NAME-
    # based — a same-name in-place recolor won't repaint. So bump the skin's
    # name field to the wallpaper basename: the gateway re-resolves, the
    # desktop sees a real name change, and repaints. No flash; display.skin
    # stays `wallust`. wallust won't create the skins dir, so mkdir it.
    mkdir -p "${hermesSkinsDir}"
    base="$(basename "$wp")"
    skin_name="$(echo "''${base%.*}" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"
    skin_name="''${skin_name:-wallust}"
    sed -i "s/^name:.*/name: $skin_name/" "${hermesSkinsDir}/wallust.yaml"

    # Set the live desktop background with a wipe transition (left-to-right).
    # awww-daemon persists from spawn-at-startup; we NEVER pkill it (killing it
    # would drop the background / break the socket). If awww img fails, surface
    # the error.
    export WAYLAND_DISPLAY="wayland-1"
    ${pkgs.awww}/bin/awww img "$wp" --transition-type wipe --transition-angle 45 --transition-duration 0.8

    # Persist the choice so a rebuild/login restores it (read by awww-wallpaper
    # systemd service) instead of resetting to the hardcoded default.
    echo "$wp" > "${wallustCfgDir}/last-wallpaper"

    ${pkgs.libnotify}/bin/notify-send "wallust" "Themed from $(basename "$wp")" 2>/dev/null || true
  '';

  # fuzzel-dmenu launcher: pick wallpaper -> wallust-apply. Kept as the text-menu
  # fallback; the QuickShell diamond picker (Phase 6) calls wallust-apply directly.
  wallust-switch = pkgs.writeShellScriptBin "wallust-switch" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    # Scan every wallpaper dir; print "dir/basename" lines. fuzzel shows the
    # basename (with dir prefix only on collision, rare — ponytail: accept dupes).
    list_wallpapers() {
      for d in ${lib.concatStringsSep " " (map (d: "\"${d}\"") wallpaperDirs)}; do
        [ -d "$d" ] || continue
        ${pkgs.findutils}/bin/find "$d" -maxdepth 1 -type f \
          \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) -print
      done | ${pkgs.coreutils}/bin/sort -t/ -k2
    }

    choice="$(list_wallpapers | ${pkgs.gnugrep}/bin/grep -o '[^/]*$' | ${pkgs.fuzzel}/bin/fuzzel --dmenu --prompt 'Wallpaper: ')"
    [ -n "$choice" ] || exit 0

    wp="$(list_wallpapers | ${pkgs.gnugrep}/bin/grep -F "/''${choice}" | head -n1)"
    [ -n "$wp" ] || { echo "wallust-switch: not found: $choice" >&2; exit 1; }
    exec ${wallust-apply}/bin/wallust-apply "$wp"
  '';
in {
  # ---- packages ----
  # awww-daemon is provided by modules/awww (systemd user services `awww` +
  # `awww-wallpaper`). We do NOT add awww here or spawn our own daemon — the
  # switcher below calls the systemd-managed daemon.
  home.packages = with pkgs; [
    wallust # v3.5.x dynamic theming engine
    libnotify # notify-send from the switcher
    wallust-apply # shared apply logic (fuzzel menu + QuickShell picker)
    wallust-switch # fuzzel launcher defined above
  ];

  # ---- wallust config + templates (wallust owns these files) ----
  home.file.".config/wallust/wallust.toml".text = ''
    # Wallust v3 config. Generated by home-manager (modules/wallust).
    # Wallpapers source: wallpaper.dirs (infernixos defaults + extraDirs)
    #
    # Templates render with {{color0}}..{{color15}}, {{background}}, {{foreground}},
    # {{cursor}}, {{alpha}}. (Verified: accent/wallpaper do NOT resolve.)

    [templates]
    fuzzel = { template = "fuzzel.tmpl", target = "${config.xdg.configHome}/fuzzel/fuzzel.ini" }
    kitty = { template = "kitty.tmpl", target = "${config.xdg.configHome}/kitty/kitty.conf" }
    niri = { template = "niri.tmpl", target = "${config.xdg.configHome}/niri/colors.kdl" }
    # QuickShell bar palette (Phase 2b): a tiny JSON the running bar watches and
    # crossfades via ColorAnimation/Behavior. Lives next to the bar config dir so
    # the path always exists; wallust owns it, HM never writes it.
    quickshell = { template = "quickshell.tmpl", target = "${config.xdg.configHome}/quickshell/wallust-palette.json" }
    zen = { template = "zen.tmpl", target = "${config.xdg.configHome}/zen/${zenProfileDir}/chrome/userChrome.css" }
    # Discord (via Vesktop): wallust writes Vencord's QUICK CSS file, which is
    # ALWAYS applied (settings useQuickCss=true) and HOT-RELOADS on write
    # (verified from Vencord src/main/ipcMain.ts: a debounced FSWatcher posts
    # QUICK_CSS_UPDATE on change). So the theme updates LIVE on Mod+W — no
    # restart, no enabledThemes toggle. Path = <userData>/settings/quickCss.css
    # = ~/.config/vesktop/settings/quickCss.css. wallust owns the file.
    discord = { template = "discord.tmpl", target = "${config.xdg.configHome}/vesktop/settings/quickCss.css" }
    # Vesktop's OWN settings store (~/.config/vesktop/settings.json) — distinct
    # from the Vencord quickCss.css target above. splashBackground is the color
    # the main window paints while Discord boots (before the page paints), so
    # setting it to {{background}} kills the white flash (Gage 08-30): the window
    # opens dark and fades into the loaded theme instead of Electron's white
    # default. splashTheming defaults true, so this color is the one used
    # (src/main/mainWindow.ts: `splashTheming ? splashBackground : ...`).
    # enableSplashScreen:false lives here too (no splash window). Vesktop
    # rewrites this file at runtime; wallust re-renders it on every Mod+W.
    vesktop-settings = { template = "vesktop-settings.tmpl", target = "${config.xdg.configHome}/vesktop/settings.json" }
        # Hermes desktop (Electron GUI): a skin YAML in the gateway's skins dir.
    # The gateway's skin watcher polls (active skin name, skins/<name>.yaml
    # mtime) and broadcasts skin.changed on any move; the desktop repaints on a
    # NAME change (backend-sync.ts guard is name-based). wallust-apply bumps the
    # name field to the wallpaper basename after each render, so Mod+W live-
    # rethemes the desktop with no flash. display.skin is set to `wallust` in
    # modules/hermes-agent. wallust owns the file.
    hermes = { template = "hermes.tmpl", target = "${hermesSkinsDir}/wallust.yaml" }
    # Pyre (PySide6+QML file manager): renders a QtObject Theme.qml that theme.py
    # reads at launch. wallust owns the file; the ~/.config/pyre target dir is
    # mkdir'd in wallust-apply (wallust doesn't create parent dirs). Takes effect
    # on next pyre launch / Mod+W.
    pyre = { template = "pyre.tmpl", target = "${config.xdg.configHome}/pyre/Theme.qml" }
  '';

  # fuzzel launcher theme — mirrors the QuickShell bar's wallust palette
  # (keys bg/fg/accent/gold/muted/urgent/green/blue) so the launcher and the
  # bar share ONE cohesive look. Re-themed live on every Mod+W (wallust owns
  # ~/.config/fuzzel/fuzzel.ini; HM writes it ONLY when settings != {}).
  # Crossfade approach: the bar fades old->new on palette change; fuzzel is a
  # transient overlay so it picks up the new palette instantly on next launch —
  # no separate animation needed, but the palette *keys* match so the look is
  # continuous with the bar's staged crossfade.
  home.file.".config/wallust/templates/fuzzel.tmpl".text = ''
    [main]
    # Smooth UI sans to match the bar (Inter). use-bold lets the selected
    # entry read as bold, tinted by the palette.
    font=Inter:size=24
    use-bold=yes
    layer=top
    # Text-only menu — no application icons (per Gage).
    icons-enabled=no
    # Narrow + tall window (per Gage): compact width, many lines.
    lines=24
    width=40
    horizontal-pad=16
    vertical-pad=16
    inner-pad=12
    letter-spacing=0.4
    anchor=center
    # Show "N/M" match count on the prompt's right — muted palette tone.
    match-counter=yes
    hide-before-typing=no
    show-actions=no
    sort-result=yes
    match-mode=fzf

    [colors]
    # fuzzel 1.14.1 requires RGBA (8-digit) hex. wallust emits 6-digit, so we
    # append a literal alpha to each placeholder (verified: {{background}}ed ->
    # #242424ed). Background alpha ~0.93 (ed) matches the bar's surface opacity;
    # every other color is fully opaque (ff) so selection/border/match read true.
    background={{background}}f2
    text={{foreground}}ff
    # Prompt + placeholder in the muted/secondary palette tone (not the old
    # hard goldenrod) — calmer, matches the bar's muted accents.
    prompt={{color8}}ff
    placeholder={{color8}}ff
    input={{foreground}}ff
    message={{color8}}ff
    # Matched substring: gold accent (was a muddy blue) — pops against the bg.
    match={{color3}}ff
    # Selection: accent fill, bg-tinted text, gold matched substring. Mirrors
    # the bar's focused-workspace accent treatment. NOTE: fuzzel's color key for
    # the selection background is `selection`, NOT `selection-background`.
    selection={{color5}}ff
    selection-text={{background}}ff
    selection-match={{color3}}ff
    # Border: accent, slightly thicker + rounded like the bar.
    border={{color5}}ff
    # Match counter (enabled above) in muted tone.
    counter={{color8}}ff

    [border]
    width=1
    radius=0
    selection-radius=0
  '';

  # Kitty terminal theme — mirrors the wallust palette (same 8-key set as the
  # bar/fuzzel) so the terminal recolors live with everything else. wallust
  # owns ~/.config/kitty/kitty.conf; HM writes it ONLY when settings != {}.
  # Kitty reads the file on next launch.
  home.file.".config/wallust/templates/kitty.tmpl".text = ''
    # shell integration (was the only line HM used to manage)
    shell_integration no-rc
    confirm_os_window_close 0
    font_family      Inter
    font_size        13.0
    background       {{background}}
    foreground       {{foreground}}
    cursor           {{color5}}
    cursor_text_color {{background}}
    selection_background {{color5}}
    selection_foreground {{background}}
    # Title bar / active tab text + icons use the same accent color as the
    # bar's clock (barAccent = color5), so the terminal's chrome matches it.
    active_tab_foreground {{color5}}
    color0 {{color0}}
    # color1 (dark red / urgent) -> color4 (terracotta): the NH generation diff
    # renders old values in dark red (color1), which is nearly black on the dark
    # bg. Remap to the terracotta the palette's color4 slot generates (#CB5E37 on
    # this wallpaper) so it's visible but still distinct from the green new values.
    color1 {{color4}}
    # color2 (regular green) -> accent: bash's PS1 renders the prompt
    # [user@host:dir]$ in bold green (ANSI 1;32), which kitty draws in the
    # REGULAR green slot (color2) with bold weight — NOT the bright slot.
    # Setting color2 to the accent makes the shell prompt match the bar's
    # clock text (barAccent = color5). (Gage, 08-30; color10 was a dead end)
    color2 {{color5}}
    color3 {{color3}}
    color4 {{color4}}
    color5 {{color5}}
    color6 {{color6}}
    color7 {{color7}}
    color8 {{color8}}
    color9 {{color9}}
    color10 {{color10}}
    color11 {{color11}}
    color12 {{color12}}
    color13 {{color13}}
    color14 {{color14}}
    color15 {{color15}}
  '';

  home.file.".config/wallust/templates/niri.tmpl".text = ''
    layout {
        background-color "{{background}}"
        focus-ring {
            active-color "{{color5}}"
        }
    }
  '';

  home.file.".config/wallust/templates/quickshell.tmpl".text = ''
    {
      "bg": "{{background}}",
      "fg": "{{foreground}}",
      "accent": "{{color5}}",
      "gold": "{{color3}}",
      "muted": "{{color8}}",
      "urgent": "{{color9}}",
      "green": "{{color2}}",
      "blue": "{{color4}}"
    }
  '';

  # Discord theme template (via Vesktop). Maps the wallust palette onto
  # Discord's CSS variables with a normal layered look. CORRECTED 08-30 (live
  # discovery via the DOM dump): Discord's current "visual refresh" build
  # draws its main surfaces from the --background-base-* / --background-
  # surface-* token families, NOT the legacy --background-primary/secondary
  # ones (those are now mostly dead). The first pass only set legacy tokens,
  # so surfaces stayed near-black (Discord default). This sets BOTH families,
  # plus --custom-theme-base-color which the build color-mixes every surface
  # from. !important so Discord's own .theme-dark blocks can't beat it.
  # wallust owns the file.
  home.file.".config/wallust/templates/discord.tmpl".text = ''
    /* wallust — recolors Discord (Vesktop) to match the current wallpaper. */
    .theme-dark {
      /* Built-in tint hook: the visual-refresh build derives all base surfaces
         via color-mix(... var(--custom-theme-base-color, #000) ...). Setting it
         tints the whole app toward our palette in one move. */
      --custom-theme-base-color: {{background}} !important;

      /* NEW visual-refresh token family — the ones the current build reads. */
      /* Chat/message-history background: message-history surfaces (base-lower,
         surface-*) set to {{background}} (Gage 08-30). base-lowest/base-low
         (chat + sidebar) stay {{color0}}. Straight variable swap, no color-mix. */
      --background-base-lowest: {{background}} !important;
      --background-base-low: {{color0}} !important;
      --background-base-lower: {{background}} !important;
      --background-accent: {{color5}} !important;
      --background-surface-high: {{background}} !important;
      --background-surface-higher: {{background}} !important;
      --background-surface-highest: {{color4}} !important;

      /* Legacy token family — still used by modals/popovers/some surfaces. */
      --background-primary: {{background}} !important;
      --background-primary-alt: {{background}} !important;
      --background-secondary: {{color0}} !important;
      --background-secondary-alt: {{color1}} !important;
      --background-tertiary: {{color1}} !important;
      --background-floating: {{color1}} !important;
      --background-modifier-hover: {{color1}} !important;
      --background-modifier-active: {{color4}} !important;
      --background-modifier-selected: {{color4}} !important;
      --background-modifier-accent: {{color5}} !important;
      --channeltextarea-background: {{color1}} !important;
      --background-modifier-border: {{color8}} !important;
      /* Border token family — Discord's visual-refresh uses --border-* for
         control outlines (the typing box border was unthemed and showed
         default blurple). Muted/grey from the palette (Gage 08-30). */
      --border-muted: {{color8}} !important;
      --border-subtle: {{color8}} !important;
      --border-normal: {{color8}} !important;
      --border-strong: {{color8}} !important;
      --border-focus: {{color5}} !important;
      --text-normal: {{foreground}} !important;
      --text-muted: {{color8}} !important;
      --text-faint: {{color8}} !important;
      --text-link: {{color4}} !important;
      --text-positive: {{color2}} !important;
      --text-warning: {{color3}} !important;
      --text-danger: {{color9}} !important;
      --header-primary: {{foreground}} !important;
      --header-secondary: {{color8}} !important;
      --interactive-normal: {{foreground}} !important;
      --interactive-hover: {{color5}} !important;
      --interactive-active: {{color5}} !important;
      --interactive-muted: {{color8}} !important;
      --brand-experiment: {{color5}} !important;
      --brand-experiment-hover: {{color4}} !important;
      --brand-experiment-active: {{color5}} !important;
      --brand-experiment-600: {{color5}} !important;
      --brand-experiment-560: {{color5}} !important;
      --brand-experiment-500: {{color5}} !important;
      --brand-experiment-430: {{color4}} !important;
      --brand-experiment-400: {{color4}} !important;
      --accent: {{color5}} !important;
      --green: {{color2}} !important;
      --red: {{color9}} !important;
      --yellow: {{color3}} !important;
      --spinner-default: {{color5}} !important;
    }
  '';

  # Vesktop's OWN settings template (JSON). wallust renders ~/.config/vesktop/
  # settings.json so splashBackground tracks the wallpaper palette — the main
  # window paints this while Discord boots, killing the white flash (Gage
  # 08-30). Pure JSON: wallust writes it verbatim, no comments allowed.
  home.file.".config/wallust/templates/vesktop-settings.tmpl".text = ''
    {
      "discordBranch": "stable",
      "minimizeToTray": true,
      "arRPC": true,
      "enableSplashScreen": false,
      "splashBackground": "{{background}}"
    }
  '';

  # Hermes desktop skin template. Maps the wallust palette onto the Hermes
  # skin schema (apps/shared/src/skin.ts). wallust renders this to the
  # gateway's skins dir; the gateway broadcasts skin.changed on mtime move and
  # the desktop repaints on a NAME change. wallust-apply bumps the name field
  # to the wallpaper basename after each render so Mod+W live-retemes the
  # desktop. wallust owns the file.
  home.file.".config/wallust/templates/hermes.tmpl".text = ''
    name: wallust
    description: wallust — live wallpaper theme

    colors:
      background: "{{background}}"
      ui_accent: "{{color5}}"
      banner_accent: "{{color5}}"
      banner_title: "{{foreground}}"
      banner_text: "{{foreground}}"
      ui_text: "{{foreground}}"
      banner_dim: "{{color8}}"
      banner_border: "{{color8}}"
      ui_border: "{{color8}}"
      ui_ok: "{{color2}}"
      ui_warn: "{{color3}}"
      ui_error: "{{color9}}"
      prompt: "{{foreground}}"
      input_rule: "{{color5}}"
      response_border: "{{color5}}"
      status_bar_bg: "{{color0}}"
      status_bar_text: "{{foreground}}"
      status_bar_good: "{{color2}}"
      status_bar_warn: "{{color3}}"
      status_bar_critical: "{{color9}}"
      session_label: "{{color5}}"
      session_border: "{{color8}}"
  '';

  # Pyre (PySide6+QML file manager) theme template. Renders a QtObject Theme.qml
  # that theme.py reads at launch. CONTRACT with the app (theme.py already
  # expects these EXACT property names — do NOT rename): bg fg accent selection
  # selectionFg sidebarBg border hover statusBg color0..color15. wallust vars
  # verified resolvable: {{background}} {{foreground}} {{colorN}} (accent/
  # wallpaper do NOT resolve) — so accent=color5, sidebarBg=color0, border=color8.
  home.file.".config/wallust/templates/pyre.tmpl".text = ''
    // Theme.qml — GENERATED BY WALLUST. Do not edit by hand.
    import QtQuick
    QtObject {
        id: theme
        property color bg: "{{background}}"
        property color fg: "{{color5}}"
        property color accent: "{{color5}}"
        property color selection: "{{color5}}"
        property color selectionFg: "{{background}}"
        property color sidebarBg: "{{background}}"
        property color border: "{{color8}}"
        property color hover: "{{background}}"
        property color statusBg: "{{background}}"
        property color color0: "{{color0}}"
        property color color1: "{{color1}}"
        property color color2: "{{color2}}"
        property color color3: "{{color3}}"
        property color color4: "{{color4}}"
        property color color5: "{{color5}}"
        property color color6: "{{color6}}"
        property color color7: "{{color7}}"
        property color color8: "{{color8}}"
        property color color9: "{{color9}}"
        property color color10: "{{color10}}"
        property color color11: "{{color11}}"
        property color color12: "{{color12}}"
        property color color13: "{{color13}}"
        property color color14: "{{color14}}"
        property color color15: "{{color15}}"
    }
  '';

  # Zen Browser chrome template. Maps the wallust palette onto Zen's UI chrome
  # via userChrome.css.
  #
  # LESSON (verified 08-30 via the live red-canary test): this build of Zen does
  # NOT honor a wallust `:root { --zen-*: ... !important }` variable block — the
  # sheet loads (element-level rules apply) but inherited custom properties do
  # not. The decisive fix is to style chrome ELEMENTS directly and set
  # background-color/color on the specific surfaces, exactly like the red-canary
  # rule that worked live (#navigator-toolbox/#TabsToolbar... background:red
  # !important). So the template targets elements, not :root variables. (A
  # minimal variable block is kept as a secondary/best-effort layer only.)
  # Loaded at BROWSER STARTUP. wallust owns chrome/userChrome.css; keep the zen
  # module's userChrome option empty to avoid a conflicting home-manager write.
  home.file.".config/wallust/templates/zen.tmpl".text = ''
    /* wallust — recolors Zen Browser chrome to match the current wallpaper. */
    :root {
      /* Best-effort variable layer (secondary — see lesson above). */
      /* ROOT-CAUSE FIX: the default theme resolves all its surfaces from light
         tokens (--toolbar-color-scheme: light) — that's WHY whites kept
         reappearing in new spots. Force the whole chrome to dark color-scheme
         so light-dark()/system colors resolve dark in one shot, collapsing the
         default theme's light leaves. Element rules below stay as belt-and-
         suspenders for specific layers. */
      color-scheme: dark !important;
      --toolbar-color-scheme: dark !important;
      --zen-border-radius: 0px !important;
      --zen-primary-color: {{color5}} !important;
      --zen-primary: {{color5}} !important;
      --zen-colors-secondary: {{color0}} !important;
      --zen-colors-tertiary: {{color0}} !important;
      --zen-main-browser-background: {{background}} !important;
      --zen-main-browser-background-toolbar: {{background}} !important;
      --zen-themed-toolbar-bg: {{background}} !important;
    }

    /* SYSTEMIC FIX: the earlier `:root { color-scheme: dark }` rule only sets
       the scheme ONCE at the root — it's inherited, so any element that
       declares its OWN scheme still beats it (that's why whites kept popping
       up on new elements one at a time). A universal `*` rule sets the scheme
       DIRECTLY on every element, so none can override it — no matter what
       surface Zen reveals later. This is the tree-killer; the element rules
       below stay as harmless belt-and-suspenders. */
    * {
      color-scheme: dark !important;
      --toolbar-color-scheme: dark !important;
    }

    /* Off-white wash behind the webpage viewport. Verified via browser-toolbox
       DOM: the main <browser> element carries a translucent rgba(255,255,255,0.1)
       background across the whole viewport — a 10% white wash that reads as dull
       light-grey over our dark wrapper. Making it transparent lets {{background}}
       (on #zen-main-app-wrapper) show through clean. Same issue the "Transparent
       Zen" mod solves; we do it declaratively here. */
    #tabbrowser-tabpanels browser,
    #tabbrowser-tabpanels browser#content {
      background-color: transparent !important;
    }

    /* The <browser> above is transparent, so whatever is BEHIND the viewport
       shows through where no page is loaded. Since the window is now a
       transparent ARGB surface (zen.widget.linux.transparency), make the
       viewport parent stack transparent too — so a NEW/EMPTY tab (no page
       loaded) shows the wallpaper instead of a dark box. Loaded pages paint
       their own background, so real webpages stay opaque; only the empty
       new-tab region goes transparent. */
    #tabbrowser-tabpanels,
    #tabbrowser-tabpanels deck,
    #tabbrowser-tabpanels .browserStack,
    #tabbrowser-tabpanels .browserSidebarContainer {
      background-color: transparent !important;
    }

    /* White background layers → recolor to wallust background. Verified via
       browser-toolbox DOM: the default theme paints these near-white even
       though we color the chrome on top. #zen-main-app-wrapper is the root
       canvas behind everything; #zen-toolbar-background sits behind the
       toolbar; #sidebar-container + splitter behind the sidebar. */
    #zen-main-app-wrapper,
    #zen-toolbar-background,
    #sidebar-container,
    #sidebar-launcher-splitter {
      background-color: {{background}} !important;
    }

    /* #zen-toolbar-background carries an INLINE --zen-main-browser-background-
       toolbar: rgba(240,240,244,1) (near-white) that shadows our :root override
       — an inline var on the element beats the inherited :root value. It shows
       as a white toolbar only when the sliding/collapsed mode reveals it. Set
       the var ON THE ELEMENT so our value wins over the inline one. */
    #zen-toolbar-background {
      --zen-main-browser-background-toolbar: {{background}} !important;
    }

    /* Light frame/border + default-theme gradient. Verified via browser-toolbox
       probes: #navigator-toolbox.chrome-block carries a near-white
       outline=rgb(250,251,246) around the whole toolbox (the white window
       frame), and Zen's default --zen-theme.gradient paints a light gradient as
       a background-image on the floating toolbar header — which our
       background-color:{{background}} doesn't override (an image sits on top).
       Kill both so the dark chrome is uninterrupted. */
    #navigator-toolbox {
      outline: none !important;
      background-image: none !important;
    }
    #zen-toolbar-background,
    #zen-main-app-wrapper {
      background-image: none !important;
    }

    /* Reveal-on-hover navbar wrapper (#zen-appcontent-navbar-wrapper) — the
       auto-hiding top bar. It still resolves --toolbar-color-scheme: light
       (the default) because Zen IGNORES the :root var override; so its
       --toolbar-background-color takes the light branch = a white band when
       shown. Style it element-directly, like every fix that actually works. */
    #zen-appcontent-navbar-wrapper,
    /* The actual container from the DOM dump (id="zen-appcontent-navbar-
       container", holding the PersonalToolbar + window-control min/max/close
       buttons). Distinct from the wrapper — it was still white because we
       only styled the wrapper. */
    #zen-appcontent-navbar-container,
    #zen-appcontent-navbar-container .titlebar-buttonbox-container,
    #zen-appcontent-navbar-container .titlebar-buttonbox {
      background-color: transparent !important;
      background-image: none !important;
      color-scheme: dark !important;
      color: {{foreground}} !important;
    }

    /* The empty-tab box. #zen-appcontent-wrapper spans the whole app region
       and #zen-tabbox-wrapper wraps the tabbox (viewport + sidebar) inside it.
       Both must be translucent BACKGROUND (alpha), NOT opacity — opacity on an
       ancestor would fade the loaded webpage too (it's a descendant), and the
       page must stay solid. A translucent background only tints the empty
       box's own backdrop; loaded pages paint their own background on top and
       stay opaque. Gage wants the outer box 90% dark (partial see-through),
       with the inner tabbox fully transparent (0) so the wallpaper shows. */
    #zen-appcontent-wrapper {
      background-color: color-mix(in srgb, {{background}} 90%, transparent) !important;
      background-image: none !important;
      color-scheme: dark !important;
      color: {{foreground}} !important;
    }
    #zen-tabbox-wrapper {
      background-color: transparent !important;
      background-image: none !important;
      color-scheme: dark !important;
      color: {{foreground}} !important;
    }

    /* Sidebar splitter (#zen-sidebar-splitter) — force it permanently
       invisible. Zen's default is already opacity:0, but its :hover rule
       (opacity:1 + --zen-primary-color) reveals it and shows white grips at
       top/bottom. opacity:0 !important beats the hover rule (important > the
       hover's higher specificity), so it never shows. Element stays so
       drag-to-resize still works. */
    #zen-sidebar-splitter {
      background-color: {{background}} !important;
      border-color: transparent !important;
      color: {{foreground}} !important;
      border-radius: 0 !important;
      opacity: 1 !important;
    }

    /* Root foreground: #main-window AND body both resolve white (body sets its
       own `color: var(--toolbox-text-color)` which overrides inheritance from
       #main-window — computed on body is rgb(255,255,255)). Zen derives many
       surfaces from currentColor (button/hover/selected/reveal bg are
       color-mix(in srgb, currentColor N%, transparent)). Leaving the root(s)
       white makes every currentColor-derived surface resolve a white tint —
       incl. the reveal-on-hover navbar and sidebar top/bottom. Set BOTH roots
       to our palette so currentColor everywhere resolves dark. */
    #main-window,
    body {
      color: {{foreground}} !important;
    }

    /* Main browser chrome / frame + tab strip + nav bar */
    #navigator-toolbox,
    #TabsToolbar,
    #tabbrowser-tabs,
    #tabbrowser-arrowscrollbox,
    #nav-bar,
    #PersonalToolbar {
      background-color: {{background}} !important;
      color: {{foreground}} !important;
    }

    /* Tab backgrounds: inactive vs active (accent). Inactive tabs use the
       muted "surface" tone ({color8}, the sage secondary slot) instead of the
       near-{background} {color0}, which disappeared into the chrome (flat) — the
       rice's established secondary-surface tone (same slot as fuzzel's prompt/
       counter + the bar's muted key). */
    #tabbrowser-tabs .tabbrowser-tab .tab-background {
      background-color: {{color8}} !important;
    }
    #tabbrowser-tabs .tabbrowser-tab[selected] .tab-background {
      background-color: {{color5}} !important;
    }
    #tabbrowser-tabs .tab-content {
      color: {{foreground}} !important;
    }

    /* URL bar: background + text. The floating/breakout urlbar's inner
       `.urlbar-input-container` resolves its own light scheme (computed dump
       color-scheme:light, 62px) — same reveal-surface mechanism as the
       toolbar. Cover it and force dark element-directly.
       NOTE (09-02): the bar FLOATING ON STARTUP is NOT a CSS problem — it is
       Zen's "Floating URL bar" feature auto-opening at launch, driven by the
       `zen.urlbar.open-on-startup` pref (set false in modules/zen/default.nix)
       plus `zen.urlbar.behavior`/`replace-newtab`. No CSS can stop that
       auto-open; the pref is the fix. These element rules only theme the bar's
       appearance when it IS shown (color8 surface, dark). */
    #urlbar-background,
    #urlbar,
    .urlbar-input-container {
      background-color: {{color8}} !important;
      color: {{foreground}} !important;
      color-scheme: dark !important;
      background-image: none !important;
    }

    /* SEARCH-DIALOG GHOST FIX: the floating/breakout (and Zen "floating urlbar")
       search/urlbar "dialog" draws its own translucent grey rounded rectangle —
       Zen's `#urlbar[breakout-extend] .urlbar-background` sets
       `background-color: var(--zen-urlbar-background-transparent/base)` + a big
       acrylic backdrop-filter + a light outline, all `!important`, which BEATS our
       plain `#urlbar-background` rule (higher specificity), So while the search
       dialog is open ours loses and Zen's translucent grey box shows. When the dialog
       collapses, that translucent surface lingers/as a ghost. Override it element-
       directly with ≥ specificity (our sheet loads after the builtin, so equal-
       specificity `!important` wins) — force the same muted surface tone, clear
       the acrylic/box-shadow/outline so nothing translucent/shadowed lingers. */
    #urlbar[breakout-extend] .urlbar-background,
    #urlbar[zen-floating-urlbar="true"] .urlbar-background,
    #urlbar[breakout] .urlbar-background {
      --zen-urlbar-background-base: {{color8}} !important;
      --zen-urlbar-background-transparent: {{color8}} !important;
      background-color: {{color8}} !important;
      background-image: none !important;
      box-shadow: none !important;
      backdrop-filter: none !important;
      outline: none !important;
    }

    /* Sidebar webpanels backdrop */
    #sidebar,
    #sidebar-box {
      background-color: {{background}} !important;
      color: {{foreground}} !important;
    }

    /* Corner radius: flatten ALL rounded surfaces (this build ignores :root
       variables — the 8px radius is HARDCODED on the native background stack.
       Verified via browser-toolbox DOM: body, #zen-main-app-wrapper, and
       #zen-browser-background all carry border-radius:8px even with
       --zen-border-radius:0. Flatten all three + the webview/sidebar. */
    body,
    #zen-main-app-wrapper,
    #zen-browser-background,
    #main-window,
    #tabbrowser-tabpanels .browserSidebarContainer,
    #tabbrowser-tabpanels deck,
    #tabbrowser-tabpanels .browserStack,
    #tabbrowser-tabpanels .browserSidebarContainer .browserStack {
      border-radius: 0 !important;
    }
    #sidebar-box,
    #sidebar {
      border-radius: 0 !important;
    }

    /* Sidebar header (window controls) + footer (download/+ icons) bands —
       the default theme paints these light; color them to the dark bg so the
       sidebar is one continuous dark column. These resolve --toolbar-color-
       scheme: light on the element itself (Zen ignores the :root override),
       so besides background, force color-scheme dark element-directly like
       the navbar wrapper. */
    #sidebar-box #titlebar,
    #sidebar-box .sidebar-header,
    #sidebar-box #zen-sidebar-top-buttons,
    #zen-sidebar-top-buttons,
    #sidebar-box #zen-sidebar-bottom-buttons,
    #zen-sidebar-bottom-buttons {
      background-color: {{background}} !important;
      background-image: none !important;
      border: none !important;
      color-scheme: dark !important;
      color: {{foreground}} !important;
    }

    /* Compact-mode white strip at the top/bottom of the hidden sidebar —
       known Zen bug (#10230), still present on 1.21.10b. The default theme
       paints an outline on the titlebar's ::before. Kill it. */
    #navigator-toolbox:not([animate='true']) #titlebar::before {
      outline: 0px !important;
    }

    /* Toolbar buttons / accents pop against the accent */
    #navigator-toolbox toolbarbutton {
      color: {{foreground}} !important;
    }

    /* CHROME TRANSLUCENCY — Gage's working combo, v2 (08-30): wallpaper shows
       through the chrome, webpage stays solid. Raw `opacity` on the chrome
       surfaces that never contain the webpage, PLUS the ENTIRE window stack
       made transparent — including the window ROOT (#main-window, body,
       #zen-browser-background) which paints opaque {{background}} and was
       blocking the reveal. The window root is the surface that actually
       reaches the compositor, so it must be transparent for wallpaper to show
       (this is why the earlier whole-window-opacity version revealed it). The
       page region (#tabbrowser-tabpanels) keeps its own opaque {{background}}
       from the white-eradication work, so the page stays solid. No blur. */
    #main-window,
    body,
    #zen-browser-background,
    #zen-main-app-wrapper,
    #zen-toolbar-background,
    #sidebar-container,
    #sidebar-launcher-splitter {
      background-color: transparent !important;
      background-image: none !important;
    }
    #navigator-toolbox,
    #TabsToolbar,
    #tabbrowser-tabs,
    #nav-bar,
    #PersonalToolbar,
    #sidebar,
    #sidebar-box {
      opacity: 0.85 !important;
    }
  '';

  # ---- niri colors: ENABLED via include (nixpkgs niri 26.04) ----
  # nixpkgs' `wayland.windowManager.niri` renders ~/.config/niri/config.kdl from
  # its `settings` via the NAMED home-manager entry `xdg.configFile."niri/config.kdl"
  # (verified in the home-manager source:
  #  modules/services/window-managers/niri.nix -> xdg.configFile."niri/config.kdl",
  #  built from cfg.extraConfigEarly + cfg.settings + cfg.extraConfig).
  # We must NOT re-declare xdg.configFile."niri/config.kdl" (that triggers
  # "Conflicting managed target files"); instead we use the module's own
  # `extraConfig` hook, which appends to the END of that named entry's source.
  # The appended line pulls in wallust's runtime-generated colors.kdl.
  # `include optional=true` keeps a missing colors.kdl (pre-first-wallust-run)
  # from breaking niri startup. mkAfter ensures it lands last even if other
  # extraConfig is added elsewhere.
  wayland.windowManager.niri.extraConfig = lib.mkAfter ''
    include optional=true "colors.kdl"
  '';

  # ---- persistent background: handled by modules/awww systemd services ----
  # modules/awww starts `awww-daemon` (systemd user service `awww`) and sets the
  # initial wallpaper (`awww-wallpaper`). We deliberately do NOT spawn a second
  # daemon here — two daemons fight over the same socket and the switcher's
  # `awww img` then targets the wrong one. The switcher below just calls `awww
  # img` against the systemd-managed daemon.

  # ---- Hermes desktop: apply the wallust skin at LAUNCH, not just live ----
  # The desktop seeds the backend skin at connect with apply:false
  # (apps/desktop/src/themes/backend-sync.ts, gateway.ready handler) so a fresh
  # connect never stomps a persisted theme, and the gateway's skin watcher seeds
  # its baseline at boot (server.py `_ensure_skin_watcher` → `_note_skin_broadcast`).
  # Net: at launch NOTHING broadcasts skin.changed, so the desktop opens on its
  # default (nous) theme. Live reload works because wallust-apply rewrites the
  # skin file (mtime + name), which the watcher DOES broadcast and the desktop
  # paints (it applies any skin.changed while not yet applied). This service
  # nudges the same file's mtime a few seconds after the desktop process appears,
  # so the watcher broadcasts exactly once per launch and the desktop paints.
  # Once applied, repeat identical skin.changed events no-op (name unchanged), so
  # there's no flicker. Pattern `share/hermes-desktop` matches the live Electron
  # process (exec'd wrapper) without matching this watcher's own store path.
  systemd.user.services.hermes-desktop-skin-boot = {
    Unit = {
      Description = "Apply wallust skin to the Hermes desktop at launch";
      After = ["graphical-session.target"];
      PartOf = ["graphical-session.target"];
    };
    Service = {
      ExecStart = toString (pkgs.writeShellScript "hermes-desktop-skin-boot" ''
        SKIN="${hermesSkinsDir}/wallust.yaml"
        last=""
        while true; do
          pid=$("${pkgs.procps}/bin/pgrep" -f 'share/hermes-desktop' | "${pkgs.coreutils}/bin/head" -n1 || true)
          if [ -n "$pid" ] && [ "$pid" != "$last" ]; then
            last="$pid"
            # Desktop (re)launched: nudge the skin a few times to cover Electron
            # boot + gateway connect latency; the first post-connect touch paints.
            for d in 2 4 4; do "${pkgs.coreutils}/bin/sleep" "$d"; "${pkgs.coreutils}/bin/touch" "$SKIN"; done
          fi
          "${pkgs.coreutils}/bin/sleep" 2
        done
      '');
      Restart = "on-failure";
    };
    Install = {
      WantedBy = ["graphical-session.target"];
    };
  };
}
