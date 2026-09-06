{
  lib,
  stdenv,
  python3,
  makeWrapper,
  qt6,
}:
let
  py = python3.withPackages (ps: [ps.pyside6]);
in
stdenv.mkDerivation {
  pname = "hello-clock";
  version = "0.1.0";
  src = ./.;
  dontBuild = true;
  dontWrapQtApps = true;
  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ qt6.qtbase ];
  installPhase = ''
    mkdir -p $out/libexec $out/bin $out/share/applications
    cp main.py $out/libexec/
    makeWrapper ${py}/bin/python $out/bin/hello-clock \
      --add-flags "$out/libexec/main.py" \
      --set QT_QPA_PLATFORM "''${QT_QPA_PLATFORM:-xcb}"
    cp hello-clock.desktop $out/share/applications/
  '';
  meta.mainProgram = "hello-clock";
}
