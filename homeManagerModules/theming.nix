{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkIf mkOption types;
  cfg = config.infernixos.desktop.theming;
  configHome = config.xdg.configHome;
  wallustDir = "${configHome}/wallust";

  applyScript = pkgs.writeShellScriptBin "wallust-apply" ''
    set -euo pipefail
    wp="$1"
    [ -n "$wp" ] || exit 0
    [ -f "$wp" ] || { echo "wallust-apply: not a file: $wp" >&2; exit 1; }
    for d in fuzzel kitty niri quickshell pyre; do
      mkdir -p "$XDG_CONFIG_HOME/$d"
    done
    mkdir -p "${wallustDir}"
    ${pkgs.wallust}/bin/wallust run --config-dir "${wallustDir}" "$wp"
    echo "$wp" > "${wallustDir}/last-wallpaper"
    ${pkgs.libnotify}/bin/notify-send "wallust" "Themed from $(basename "$wp")" 2>/dev/null || true
  '';

  switchScript = pkgs.writeShellScriptBin "wallust-switch" ''
    set -euo pipefail
    WP_DIR="${toString cfg.wallpapersDir}"
    [ -d "$WP_DIR" ] || { echo "wallust-switch: wallpapers dir not set or missing" >&2; exit 1; }
    choice="$(${pkgs.findutils}/bin/find "$WP_DIR" -maxdepth 1 -type f \
      \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
      -printf '%f\n' | ${pkgs.coreutils}/bin/sort | ${pkgs.fuzzel}/bin/fuzzel --dmenu --prompt 'Wallpaper: ')"
    [ -n "$choice" ] || exit 0
    exec ${applyScript}/bin/wallust-apply "$WP_DIR/$choice"
  '';
in
{
  options.infernixos.desktop.theming = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable wallust dynamic theming: derives a palette from the active
        wallpaper and renders curated templates for fuzzel, kitty, niri,
        quickshell and pyre. Template targets live under the user config dir.
      '';
    };

    wallpapersDir = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Directory of wallpapers (jpg/png/webp) the fuzzel launcher lists and
        applies. When null the wallust-switch launcher is omitted; wallust-apply
        still themes from any image path passed to it.
      '';
    };
  };

  config = mkIf cfg.enable {
    home.packages =
      with pkgs;
      [
        wallust
        libnotify
        applyScript
      ]
      ++ lib.optionals (cfg.wallpapersDir != null) [ switchScript ];

    home.file."${wallustDir}/wallust.toml".text = ''
      [templates]
      fuzzel = { template = "fuzzel.tmpl", target = "${configHome}/fuzzel/fuzzel.ini" }
      kitty = { template = "kitty.tmpl", target = "${configHome}/kitty/kitty.conf" }
      niri = { template = "niri.tmpl", target = "${configHome}/niri/colors.kdl" }
      quickshell = { template = "quickshell.tmpl", target = "${configHome}/quickshell/wallust-palette.json" }
      pyre = { template = "pyre.tmpl", target = "${configHome}/pyre/Theme.qml" }
    '';

    home.file."${wallustDir}/templates/fuzzel.tmpl".text = ''
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

    home.file."${wallustDir}/templates/kitty.tmpl".text = ''
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

    home.file."${wallustDir}/templates/niri.tmpl".text = ''
      layout {
          background-color "{{background}}"
          focus-ring {
              active-color "{{color5}}"
          }
      }
    '';

    home.file."${wallustDir}/templates/quickshell.tmpl".text = ''
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

    home.file."${wallustDir}/templates/pyre.tmpl".text = ''
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
  };
}
