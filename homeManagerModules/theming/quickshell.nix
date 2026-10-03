{ config
, pkgs
, lib
, inputs
, ...
}:

let
  barSrc = ../quickshell-config;

  palettePath = "${config.xdg.configHome}/quickshell/wallust-palette.json";

  pickerStatePath = "${config.xdg.configHome}/quickshell/picker-state";
  hotkeysStatePath = "${config.xdg.configHome}/quickshell/hotkeys-state";
  wallpapersDirs = config.infernixos.desktop.theming.wallpaper.dirs;

  wallpaper-picker-toggle = pkgs.writeShellScriptBin "wallpaper-picker-toggle" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail
    STATE="${pickerStatePath}"
    mkdir -p "$(dirname "$STATE")"
    if [ -f "$STATE" ] && [ "$(cat "$STATE")" = "open" ]; then
      echo closed > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    else
      echo open > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    fi
  '';

  keybind-popup-toggle = pkgs.writeShellScriptBin "keybind-popup-toggle" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail
    STATE="${hotkeysStatePath}"
    mkdir -p "$(dirname "$STATE")"
    if [ -f "$STATE" ] && [ "$(cat "$STATE")" = "open" ]; then
      echo closed > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    else
      echo open > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    fi
  '';

  barConfig = pkgs.stdenv.mkDerivation {
    pname = "quickshell-bar";
    version = "1.0.0";
    src = barSrc;
    installPhase = ''
      mkdir -p $out
      cp -r . $out/
    '';
  };

  qsWrapper = pkgs.writeShellScriptBin "quickshell-bar" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail
    # QML2_IMPORT_PATH may be unset at session start (not inherited); under
    # `set -u` the bare "$QML2_IMPORT_PATH" would abort with "unbound variable".
    # Guard it so the wrapper always launches.
    if [ -z "''${QML2_IMPORT_PATH:-}" ]; then
      export QML2_IMPORT_PATH="${inputs.qml-niri.packages.${pkgs.stdenv.hostPlatform.system}.default}/lib/qt-6/qml:${pkgs.qt6.qt5compat}/lib/qt-6/qml"
    else
      export QML2_IMPORT_PATH="${inputs.qml-niri.packages.${pkgs.stdenv.hostPlatform.system}.default}/lib/qt-6/qml:${pkgs.qt6.qt5compat}/lib/qt-6/qml:$QML2_IMPORT_PATH"
    fi
    export QUICKSHELL_WALLUST_PALETTE="${palettePath}"
    export QUICKSHELL_WALLPAPER_DIRS="${lib.concatStringsSep ":" wallpapersDirs}"
    # Gateway connection — same mechanism hermes desktop uses: a runtime token
    # file read at launch (never baked into the store). Port matches the
    # nixosModule default (hermesApiServerPort); HM scope can't read it.
    export QUICKSHELL_HERMES_API_URL="http://127.0.0.1:8642"
    export QUICKSHELL_HERMES_API_KEY_PATH="/var/lib/hermes/.hermes/api-server-key"
    exec ${pkgs.quickshell}/bin/quickshell --config "${barConfig}"
  '';
in
{
  # ---- packages: quickshell, the qml-niri plugin availability, audio/network tools ----
  # quickshell itself comes from nixpkgs; qml-niri plugin is pulled via the wrapper's
  # QML2_IMPORT_PATH (so it doesn't need to be a top-level package, but we add it to
  # the env so it's inspectable).
  home.packages = with pkgs; [
    quickshell
    qsWrapper
    wallpaper-picker-toggle
    keybind-popup-toggle
    inputs.qml-niri.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];

  # ---- ship the bar QML into ~/.config/quickshell/bar so it's user-editable & live ----
  # (Phase 2b can patch these files at runtime without a rebuild, matching how
  #  wallust owns waybar/fuzzel/kitty files.)
  home.file.".config/quickshell/bar".source = barConfig;

  # Seed the picker state file to "closed" so the bar starts with the picker
  # hidden. MUST be a real writable file, NOT a home-manager store symlink —
  # home.file with `.text` creates a read-only /nix/store symlink, so the
  # wallpaper-picker-toggle script's `echo open >` would fail with "Read-only
  home.activation.createPickerState = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/.config/quickshell"
    echo "closed" > "$HOME/.config/quickshell/picker-state"
    echo "closed" > "$HOME/.config/quickshell/hotkeys-state"
  '';
}
