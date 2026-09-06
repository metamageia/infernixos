{
  lib,
  stdenv,
  python3,
  nix,
  git,
  makeWrapper,
}:
let
  py = python3.withPackages (ps: [ ]);
in
stdenv.mkDerivation {
  pname = "infernixos-runtime";
  version = "0.1.0";
  src = lib.cleanSource ./.;
  dontBuild = true;
  dontConfigure = true;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    mkdir -p $out/lib/infernixos
    cp -r infernixos $out/lib/infernixos/
    rm -rf $out/lib/infernixos/infernixos/__pycache__
    mkdir -p $out/bin
    makeWrapper ${py}/bin/python $out/bin/infernixos \
      --add-flags "-B -m infernixos" \
      --prefix PATH : ${lib.makeBinPath [ nix git ]} \
      --set PYTHONPATH $out/lib/infernixos
    makeWrapper ${py}/bin/python $out/bin/infernixos-activate \
      --add-flags "-B $out/lib/infernixos/infernixos/activate_root.py" \
      --prefix PATH : ${lib.makeBinPath [ nix git ]} \
      --set PYTHONPATH $out/lib/infernixos
  '';
  meta = {
    description = "infernixos runtime: extension lifecycle, durable Hermes jobs, human-authorized activation";
    license = lib.licenses.mit;
    mainProgram = "infernixos";
  };
}
