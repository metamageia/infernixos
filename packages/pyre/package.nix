{
  lib,
  stdenv,
  python3,
  qt6,
  kdePackages,
  hicolor-icon-theme,
  writeShellScript,
}: let
  py = python3.withPackages (ps: [ps.pyside6]);
in
  stdenv.mkDerivation {
    pname = "pyre";
    version = "0.1.0";
    src = lib.cleanSource ./.;
    dontBuild = true;
    dontConfigure = true;
    dontWrapQtApps = true;
    nativeBuildInputs = [ kdePackages.breeze-icons hicolor-icon-theme ];
    buildInputs = [ qt6.qtbase qt6.qtsvg ];
    installPhase = ''
      mkdir -p $out/libexec/pyre
      cp main.py core.py fs_model.py settings.py folder_model.py places_model.py search_model.py theme.py $out/libexec/pyre/
      cp -r qml $out/libexec/pyre/
      mkdir -p $out/bin
      cat > $out/bin/pyre <<EOF
      #!${stdenv.shell}
      export QML2_IMPORT_PATH="${qt6.qtdeclarative}/lib/qt-6/qml"
      export QT_PLUGIN_PATH="${qt6.qtbase}/lib/qt-6/plugins:${qt6.qtsvg}/lib/qt-6/plugins:\''${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
      export QT_QPA_PLATFORM="\''${WAYLAND_DISPLAY:+wayland}"
      export QT_QPA_PLATFORM="\''${QT_QPA_PLATFORM:-xcb}"
      export XDG_DATA_DIRS="${kdePackages.breeze-icons}/share:${hicolor-icon-theme}/share:\''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
      exec ${py}/bin/python $out/libexec/pyre/main.py "\$@"
      EOF
      chmod +x $out/bin/pyre
      mkdir -p $out/share/applications
      cp pyre.desktop $out/share/applications/
    '';
    meta = {
      description = "Near-1:1 Dolphin file manager in PySide6 + QML with wallust live-reload theming";
      license = lib.licenses.mit;
      mainProgram = "pyre";
    };
  }
