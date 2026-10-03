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
      spawn-at-startup = "xwayland-satellite";
      layout = {
        gaps = 8;
        focus-ring = {
          width = 1;
        };
        border = {
          active-color = "#1D1816";
          inactive-color = "#1D1816";
        };
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
        "Mod+Shift+E".quit = {};
        "Mod+Shift+Slash" = {
          spawn = ["keybind-popup-toggle"];
        };

        "Mod+D" = {
          spawn = ["fuzzel"];
        };
        "Mod+T" = {
          spawn = ["kitty"];
        };
        "Mod+P".screenshot = {};
        "Mod+W" = {
          spawn = ["wallpaper-picker-toggle"];
        };

        "XF86AudioRaiseVolume" = {
          spawn = ["wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.1+"];
        };
        "XF86AudioLowerVolume" = {
          spawn = ["wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.1-"];
        };

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
      _children = [
        {
          window-rule._children = [
            {match = {};}
            {draw-border-with-background = false;}
            {clip-to-geometry = true;}
            {geometry-corner-radius = 0;}
            {border = {width = 2;};}
          ];
        }
        {
          window-rule._children = [
            {match = {};}
            {exclude._props = {app-id = "zen";};}
            {opacity = 0.85;}
          ];
        }
      ];
    };

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

    '';
  };
}
