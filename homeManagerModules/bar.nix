{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkIf mkOption types;
  cfg = config.infernixos.desktop.bar;
  configHome = config.xdg.configHome;
  theming = config.infernixos.desktop.theming;

  barConfig = pkgs.stdenv.mkDerivation {
    pname = "quickshell-bar";
    version = "1.0.0";
    src = ./quickshell-config;
    installPhase = ''
      mkdir -p $out
      cp -r . $out/
    '';
  };

  extraQmlPaths = lib.optionalString (cfg.qmlNiri != null) "${cfg.qmlNiri}/lib/qt-6/qml:";

  pickerState = "${configHome}/quickshell/picker-state";
  hotkeysState = "${configHome}/quickshell/hotkeys-state";

  wallpaper-picker-toggle = pkgs.writeShellScriptBin "wallpaper-picker-toggle" ''
    set -euo pipefail
    STATE="${pickerState}"
    mkdir -p "$(dirname "$STATE")"
    if [ -f "$STATE" ] && [ "$(cat "$STATE")" = "open" ]; then
      echo closed > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    else
      echo open > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    fi
  '';

  keybind-popup-toggle = pkgs.writeShellScriptBin "keybind-popup-toggle" ''
    set -euo pipefail
    STATE="${hotkeysState}"
    mkdir -p "$(dirname "$STATE")"
    if [ -f "$STATE" ] && [ "$(cat "$STATE")" = "open" ]; then
      echo closed > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    else
      echo open > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    fi
  '';

  qsWrapper = pkgs.writeShellScriptBin "quickshell-bar" ''
    set -euo pipefail
    if [ -z "''${QML2_IMPORT_PATH:-}" ]; then
      export QML2_IMPORT_PATH="${extraQmlPaths}${pkgs.qt6.qt5compat}/lib/qt-6/qml"
    else
      export QML2_IMPORT_PATH="${extraQmlPaths}${pkgs.qt6.qt5compat}/lib/qt-6/qml:$QML2_IMPORT_PATH"
    fi
    export QUICKSHELL_WALLUST_PALETTE="${configHome}/quickshell/wallust-palette.json"
    export QUICKSHELL_WALLPAPERS_DIR="${
      if theming.wallpapersDir != null then toString theming.wallpapersDir else ""
    }"
    exec ${pkgs.quickshell}/bin/quickshell --config "${barConfig}"
  '';
in
{
  options.infernixos.desktop.bar = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the wallust-themed quickshell status bar (workspaces, clock,
        wifi, volume, tray). Requires the compositor to launch quickshell-bar.
      '';
    };

    qmlNiri = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = ''
        A qml-niri plugin package exposing niri IPC to quickshell. When provided
        it is prepended to the QML import path so the bar's workspace widgets
        resolve. A consumer must supply a package (qml-niri is not in nixpkgs).
      '';
    };
  };

  config = mkIf cfg.enable {
    home.packages = [
      pkgs.quickshell
      qsWrapper
      wallpaper-picker-toggle
      keybind-popup-toggle
    ];

    home.file."${configHome}/quickshell/bar".source = barConfig;

    home.activation.infernixosBarSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "${configHome}/quickshell"
      echo "closed" > "${pickerState}"
      echo "closed" > "${hotkeysState}"
    '';
  };
}
