
{
  config,
  pkgs,
  lib,
  ...
}: let
  wallpaperDirs = config.infernixos.desktop.theming.wallpaper.dirs;

  hermesSkinsDir = config.infernixos.desktop.theming.hermesSkinsDir;

  zenProfileDir = config.infernixos.desktop.theming.zenProfileDir;

  wallustCfgDir = "${config.xdg.configHome}/wallust";

  hermes-skins-dir = pkgs.writeShellScriptBin "hermes-skins-dir" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail
    explicit="${hermesSkinsDir}"
    if [ -n "$explicit" ]; then echo "$explicit"; exit 0; fi
    pid=$("${pkgs.procps}/bin/pgrep" -f 'share/hermes-desktop' | "${pkgs.coreutils}/bin/head" -n1 || true)
    if [ -n "$pid" ]; then
      home=$("${pkgs.coreutils}/bin/tr" '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
        | "${pkgs.gnugrep}/bin/grep" '^HERMES_HOME=' | "${pkgs.coreutils}/bin/cut" -d= -f2- || true)
      if [ -n "''${home:-}" ]; then echo "$home/skins"; exit 0; fi
    fi
    if [ -n "''${HERMES_HOME:-}" ]; then echo "$HERMES_HOME/skins"; exit 0; fi
    if [ -d /var/lib/hermes/.hermes/skins ]; then echo /var/lib/hermes/.hermes/skins; exit 0; fi
    echo "$HOME/.hermes/skins"
  '';

  wallust-apply = pkgs.writeShellScriptBin "wallust-apply" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail
    wp="$1"
    CONFIG_DIR="${wallustCfgDir}"

    [ -n "$wp" ] || exit 0
    [ -f "$wp" ] || { echo "wallust-apply: not a file: $wp" >&2; exit 1; }

    mkdir -p "${config.xdg.configHome}/zen/${zenProfileDir}/chrome"

    mkdir -p "${config.xdg.configHome}/pyre"

    ${pkgs.wallust}/bin/wallust run --config-dir "$CONFIG_DIR" "$wp"

    skins_dir="$(${hermes-skins-dir}/bin/hermes-skins-dir)"
    mkdir -p "$skins_dir"
    base="$(basename "$wp")"
    skin_name="$(echo "''${base%.*}" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"
    skin_name="''${skin_name:-wallust}"
    sed "s/^name:.*/name: $skin_name/" "$CONFIG_DIR/hermes-skin.yaml" > "$skins_dir/wallust.yaml"

    export WAYLAND_DISPLAY="wayland-1"
    ${pkgs.awww}/bin/awww img "$wp" --transition-type wipe --transition-angle 45 --transition-duration 0.8

    echo "$wp" > "${wallustCfgDir}/last-wallpaper"

    ${pkgs.libnotify}/bin/notify-send "wallust" "Themed from $(basename "$wp")" 2>/dev/null || true
  '';

  wallust-switch = pkgs.writeShellScriptBin "wallust-switch" ''
    set -euo pipefail

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
  home.packages = with pkgs; [
    wallust 
    libnotify 
    wallust-apply 
    wallust-switch 
    hermes-skins-dir 
  ];

  home.file.".config/wallust/wallust.toml".text = ''
    [templates]
    fuzzel = { template = "fuzzel.tmpl", target = "${config.xdg.configHome}/fuzzel/fuzzel.ini" }
    kitty = { template = "kitty.tmpl", target = "${config.xdg.configHome}/kitty/kitty.conf" }
    niri = { template = "niri.tmpl", target = "${config.xdg.configHome}/niri/colors.kdl" }
    quickshell = { template = "quickshell.tmpl", target = "${config.xdg.configHome}/quickshell/wallust-palette.json" }
    zen = { template = "zen.tmpl", target = "${config.xdg.configHome}/zen/${zenProfileDir}/chrome/userChrome.css" }
    discord = { template = "discord.tmpl", target = "${config.xdg.configHome}/vesktop/settings/quickCss.css" }
    vesktop-settings = { template = "vesktop-settings.tmpl", target = "${config.xdg.configHome}/vesktop/settings.json" }
    hermes = { template = "hermes.tmpl", target = "${wallustCfgDir}/hermes-skin.yaml" }
    pyre = { template = "pyre.tmpl", target = "${config.xdg.configHome}/pyre/Theme.qml" }
  '';

  home.file.".config/wallust/templates/fuzzel.tmpl".text = ''
    [main]
    font=Inter:size=24
    use-bold=yes
    layer=top
    icons-enabled=no
    lines=24
    width=40
    horizontal-pad=16
    vertical-pad=16
    inner-pad=12
    letter-spacing=0.4
    anchor=center
    match-counter=yes
    hide-before-typing=no
    show-actions=no
    sort-result=yes
    match-mode=fzf

    [colors]
    background={{background}}f2
    text={{foreground}}ff
    prompt={{color8}}ff
    placeholder={{color8}}ff
    input={{foreground}}ff
    message={{color8}}ff
    match={{color3}}ff
    selection={{color5}}ff
    selection-text={{background}}ff
    selection-match={{color3}}ff
    border={{color5}}ff
    counter={{color8}}ff

    [border]
    width=1
    radius=0
    selection-radius=0
  '';

  home.file.".config/wallust/templates/kitty.tmpl".text = ''
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
    active_tab_foreground {{color5}}
    color0 {{color0}}
    color1 {{color4}}
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
    overview {
        backdrop-color "{{ color5 | saturate(0.6) }}"
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

  home.file.".config/wallust/templates/discord.tmpl".text = ''
    .theme-dark {
      --custom-theme-base-color: {{background}} !important;

      --background-base-lowest: {{background}} !important;
      --background-base-low: {{color0}} !important;
      --background-base-lower: {{background}} !important;
      --background-accent: {{color5}} !important;
      --background-surface-high: {{background}} !important;
      --background-surface-higher: {{background}} !important;
      --background-surface-highest: {{color4}} !important;

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

  home.file.".config/wallust/templates/vesktop-settings.tmpl".text = ''
    {
      "discordBranch": "stable",
      "minimizeToTray": true,
      "arRPC": true,
      "enableSplashScreen": false,
      "splashBackground": "{{background}}",
      "customTitlebar": true
    }
  '';

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

  home.file.".config/wallust/templates/pyre.tmpl".text = ''
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

  home.file.".config/wallust/templates/zen.tmpl".text = ''
    :root {
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

    * {
      color-scheme: dark !important;
      --toolbar-color-scheme: dark !important;
    }

    #tabbrowser-tabpanels browser,
    #tabbrowser-tabpanels browser#content {
      background-color: transparent !important;
    }

    #tabbrowser-tabpanels,
    #tabbrowser-tabpanels deck,
    #tabbrowser-tabpanels .browserStack,
    #tabbrowser-tabpanels .browserSidebarContainer {
      background-color: transparent !important;
    }

    #zen-main-app-wrapper,
    #zen-toolbar-background,
    #sidebar-container,
    #sidebar-launcher-splitter {
      background-color: {{background}} !important;
    }

    #zen-toolbar-background {
      --zen-main-browser-background-toolbar: {{background}} !important;
    }

    #navigator-toolbox {
      outline: none !important;
      background-image: none !important;
    }
    #zen-toolbar-background,
    #zen-main-app-wrapper {
      background-image: none !important;
    }

    #zen-appcontent-navbar-wrapper,
    #zen-appcontent-navbar-container,
    #zen-appcontent-navbar-container .titlebar-buttonbox-container,
    #zen-appcontent-navbar-container .titlebar-buttonbox {
      background-color: transparent !important;
      background-image: none !important;
      color-scheme: dark !important;
      color: {{foreground}} !important;
    }

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

    #zen-sidebar-splitter {
      background-color: {{background}} !important;
      border-color: transparent !important;
      color: {{foreground}} !important;
      border-radius: 0 !important;
      opacity: 1 !important;
    }

    #main-window,
    body {
      color: {{foreground}} !important;
    }

    #navigator-toolbox,
    #TabsToolbar,
    #tabbrowser-tabs,
    #tabbrowser-arrowscrollbox,
    #nav-bar,
    #PersonalToolbar {
      background-color: {{background}} !important;
      color: {{foreground}} !important;
    }

    #tabbrowser-tabs .tabbrowser-tab .tab-background {
      background-color: {{color8}} !important;
    }
    #tabbrowser-tabs .tabbrowser-tab[selected] .tab-background {
      background-color: {{color5}} !important;
    }
    #tabbrowser-tabs .tab-content {
      color: {{foreground}} !important;
    }

    #urlbar-background,
    #urlbar,
    .urlbar-input-container {
      background-color: {{color8}} !important;
      color: {{foreground}} !important;
      color-scheme: dark !important;
      background-image: none !important;
    }

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

    #sidebar,
    #sidebar-box {
      background-color: {{background}} !important;
      color: {{foreground}} !important;
    }

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

    #navigator-toolbox:not([animate='true']) #titlebar::before {
      outline: 0px !important;
    }

    #navigator-toolbox toolbarbutton {
      color: {{foreground}} !important;
    }

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

  wayland.windowManager.niri.extraConfig = lib.mkAfter ''
    include optional=true "colors.kdl"
  '';


  systemd.user.services.hermes-desktop-skin-boot = {
    Unit = {
      Description = "Apply wallust skin to the Hermes desktop at launch";
      After = ["graphical-session.target"];
      PartOf = ["graphical-session.target"];
    };
    Service = {
      ExecStart = toString (pkgs.writeShellScript "hermes-desktop-skin-boot" ''
        skins_dir="$(${hermes-skins-dir}/bin/hermes-skins-dir)"
        SKIN="$skins_dir/wallust.yaml"
        last=""
        while true; do
          pid=$("${pkgs.procps}/bin/pgrep" -f 'share/hermes-desktop' | "${pkgs.coreutils}/bin/head" -n1 || true)
          if [ -n "$pid" ] && [ "$pid" != "$last" ]; then
            last="$pid"
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
