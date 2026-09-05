{
  config,
  pkgs,
  lib,
  ...
}: {
  wayland.windowManager.niri = {
    enable = true;

    settings = {
      clipboard.disable-primary = true;
      environment = {
        DISPLAY = ":0";
      };
      # nixpkgs home-manager's `wayland.windowManager.niri.settings` is free-form
      # KDL; a Nix *list* renders as KDL list syntax (`spawn-at-startup { - … }`)
      # which niri 26.04 rejects. niri 26.04 wants a bare command arg instead.
      # QuickShell bar (modules/quickshell) — replaces waybar (Phase 3).
      # spawn-at-startup is a singular bare-command arg in nixpkgs niri 26.04
      # (a Nix *list* renders as rejected KDL list syntax). The second spawn
      # (quickshell-bar) is appended via extraConfig below as a second node.
      spawn-at-startup = "xwayland-satellite";
      layout = {
        gaps = 8;
        focus-ring = {
          width = 1;
        };
        # Border color (niri window-rule `border` only takes width; the COLOR
        # lives here in layout.border). Default active/inactive are light —
        # that's the white frame around windows. Set both to the theme bg so
        # the frame reads as a dark hairline. NOTE: hardcoded to this
        # wallpaper's bg; niri reads config only at login so it won't rotate
        # with wallust (same limitation as colors.kdl).
        border = {
          active-color = "#1D1816";
          inactive-color = "#1D1816";
        };
        # Drop shadow for windows: small + tight gradient (Gage). Low softness
        # (tight, not a big blur), small spread, small offset. NOTE: NO
        # draw-behind-window — that painted a rectangle behind every window and
        # swallowed the wallpaper's background layer (broke it 08-29). Shadows
        # draw around windows only. `on = {}` emits bare `on`; `offset._props`
        # emits `offset x=0 y=6` (offset takes args, not a block).
        shadow = {
          on = {};
          softness = 10;
          spread = 2;
          color = "#000000c0";
          offset._props = {
            x = 0;
            y = 2;
          };
        };
      };
      binds = {
        # Niri
        "Mod+Shift+E".quit = {};
        # Phase 7: Mod+Shift+/ now spawns our themed keybind popup
        # (quickshell-hotkeys), seeded from wallust palette) INSTEAD of niri's
        # unstyleable show-hotkey-overlay (no styling options, not a layer surface).
        "Mod+Shift+Slash" = {
          spawn = ["keybind-popup-toggle"];
        };

        # Hotkeys
        "Mod+D" = {
          spawn = ["fuzzel"];
        };
        "Mod+T" = {
          spawn = ["kitty"];
        };
        "Mod+P".screenshot = {};
        # Phase 6: wallpaper/theme switcher. Mod+W now opens the QuickShell
        # diamond picker (wallpaper-picker-toggle); wallust-switch remains as the
        # text-menu fallback (see modules/wallust).
        "Mod+W" = {
          spawn = ["wallpaper-picker-toggle"];
        };

        # Audio
        "XF86AudioRaiseVolume" = {
          spawn = ["wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.1+"];
        };
        "XF86AudioLowerVolume" = {
          spawn = ["wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.1-"];
        };

        # Windows and Workspaces
        "Mod+Q".close-window = {};

        "Mod+Left".focus-column-left = {};
        "Mod+Down".focus-window-down = {};
        "Mod+Up".focus-window-up = {};
        "Mod+Right".focus-column-right = {};

        "Mod+H".focus-column-left = {};
        "Mod+J".focus-window-down = {};
        "Mod+K".focus-window-up = {};
        "Mod+L".focus-column-right = {};

        "Mod+Ctrl+Left".move-column-left = {};
        "Mod+Ctrl+Down".move-window-down = {};
        "Mod+Ctrl+Up".move-window-up = {};
        "Mod+Ctrl+Right".move-column-right = {};
        "Mod+Ctrl+H".move-column-left = {};
        "Mod+Ctrl+J".move-window-down = {};
        "Mod+Ctrl+K".move-window-up = {};
        "Mod+Ctrl+L".move-column-right = {};

        "Mod+Home".focus-column-first = {};
        "Mod+End".focus-column-last = {};
        "Mod+Ctrl+Home".move-column-to-first = {};
        "Mod+Ctrl+End".move-column-to-last = {};

        "Mod+Shift+Left".focus-monitor-left = {};
        "Mod+Shift+Down".focus-monitor-down = {};
        "Mod+Shift+Up".focus-monitor-up = {};
        "Mod+Shift+Right".focus-monitor-right = {};
        "Mod+Shift+H".focus-monitor-left = {};
        "Mod+Shift+J".focus-monitor-down = {};
        "Mod+Shift+K".focus-monitor-up = {};
        "Mod+Shift+L".focus-monitor-right = {};

        "Mod+Shift+Ctrl+Left".move-column-to-monitor-left = {};
        "Mod+Shift+Ctrl+Down".move-column-to-monitor-down = {};
        "Mod+Shift+Ctrl+Up".move-column-to-monitor-up = {};
        "Mod+Shift+Ctrl+Right".move-column-to-monitor-right = {};
        "Mod+Shift+Ctrl+H".move-column-to-monitor-left = {};
        "Mod+Shift+Ctrl+J".move-column-to-monitor-down = {};
        "Mod+Shift+Ctrl+K".move-column-to-monitor-up = {};
        "Mod+Shift+Ctrl+L".move-column-to-monitor-right = {};

        "Mod+Page_Down".focus-workspace-down = {};
        "Mod+Page_Up".focus-workspace-up = {};
        "Mod+U".focus-workspace-down = {};
        "Mod+I".focus-workspace-up = {};

        "Mod+Ctrl+Page_Down".move-column-to-workspace-down = {};
        "Mod+Ctrl+Page_Up".move-column-to-workspace-up = {};
        "Mod+Ctrl+U".move-column-to-workspace-down = {};
        "Mod+Ctrl+I".move-column-to-workspace-up = {};

        "Mod+Shift+Page_Down".move-workspace-down = {};
        "Mod+Shift+Page_Up".move-workspace-up = {};
        "Mod+Shift+U".move-workspace-down = {};
        "Mod+Shift+I".move-workspace-up = {};

        "Mod+1".focus-workspace = 1;
        "Mod+2".focus-workspace = 2;
        "Mod+3".focus-workspace = 3;
        "Mod+4".focus-workspace = 4;
        "Mod+5".focus-workspace = 5;
        "Mod+6".focus-workspace = 6;
        "Mod+7".focus-workspace = 7;
        "Mod+8".focus-workspace = 8;
        "Mod+9".focus-workspace = 9;

        "Mod+BracketLeft".consume-or-expel-window-left = {};
        "Mod+BracketRight".consume-or-expel-window-right = {};
        "Mod+Comma".consume-window-into-column = {};
        "Mod+Period".expel-window-from-column = {};

        "Mod+R".switch-preset-column-width = {};
        "Mod+Shift+R".switch-preset-window-height = {};
        "Mod+Ctrl+R".reset-window-height = {};
        "Mod+F".maximize-column = {};
        "Mod+Shift+F".fullscreen-window = {};
        "Mod+Ctrl+F".expand-column-to-available-width = {};
        "Mod+C".center-column = {};
      };
      # NOTE: niri 26.04 uses singular `match` / `exclude` (not the plural
      # `matches` / `excludes` that niri-flake's typed `settings` accepted), and
      # `geometry-corner-radius` takes a single uniform radius in 26.04 (the old
      # per-corner nested form is rejected). The nixpkgs home-manager
      # `wayland.windowManager.niri.settings` is free-form KDL; a Nix *list*
      # renders as KDL list syntax (`window-rules { - … }`) which niri rejects,
      # so window-rules are emitted via `settings._children` as top-level
      # `window-rule {…}` nodes.
      _children = [
        # Geometry Rules (apply to all windows)
        {
          window-rule._children = [
            {match = {};}
            {draw-border-with-background = false;}
            {clip-to-geometry = true;}
            {geometry-corner-radius = 0;}
            # Window border: niri's window-rule `border` only accepts `width`
            # (a `color` key here is INVALID — broke the build). The border is
            # drawn in the focus-ring's active-color, so the white frame is
            # fixed by setting active-color dark (see layout.focus-ring below).
            {border = {width = 2;};}
          ];
        }
        # Opacity Rules (all windows except zen)
        {
          window-rule._children = [
            {match = {};}
            {exclude._props = {app-id = "zen";};}
            {opacity = 0.85;}
          ];
        }
      ];
    };

    # Spawn the QuickShell bar at session start (replaces waybar, Phase 3).
    # Emitted via extraConfig (not settings._children) because the nixpkgs
    # home-manager KDL generator drops a bare `{"spawn-at-startup" = …}` _children
    # entry; raw extraConfig nodes are preserved verbatim. Window-rules above stay
    # in _children (they render fine); only the bare spawn node was skipped.
    #
    # Layer-rule drop shadows for fuzzel ("launcher") and the QuickShell bar
    # ("quickshell-bar" namespace, set in shell.qml). These live here as RAW KDL
    # because the free-form converter inlines layer-rule shadow props onto one
    # line (rejected by niri). Same small/tight shadow as windows: no
    # draw-behind-window, low softness, small spread/offset.
    extraConfig = ''
      spawn-at-startup "quickshell-bar"

      layer-rule {
        match namespace="^launcher$"
        shadow {
          on
          softness 10
          spread 2
          offset x=0 y=2
          color "#000000c0"
        }
      }

      layer-rule {
        match namespace="^quickshell-bar$"
        shadow {
          on
          softness 10
          spread 2
          offset x=0 y=2
          color "#000000c0"
        }
      }

      // Phase 7: the keybind/hotkey popup's shadow, same tight drop shadow as
      // the bar/fuzzel (namespace quickshell-hotkeys, set in shell.qml). A window
      // shadow draws around the window box =the popup panel fits tight to content.

      layer-rule {
        match namespace="^quickshell-hotkeys$"
        shadow {
          on
          softness 10
          spread 2
          offset x=0 y=2
          color "#000000c0"
        }
      }

      // Phase 6: the wallpaper picker's shadow is per-DIAMOND (in QML,
      // WallpaperHive DropShadow), NOT a window-level layer-rule — a window
      // shadow would cast a big box around the transparent picker surface
      // (Gage, 08-29). Only the bar keeps its layer-rule shadow.
    '';
  };
}
