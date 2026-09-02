{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkIf mkMerge mkOption types;
  cfg = config.infernixos.desktop;

  curatedApps = {
    pyre = pkgs.callPackage ../packages/pyre/package.nix { };
    fuzzel = pkgs.fuzzel;
    kitty = pkgs.kitty;
    niri = pkgs.niri;
    quickshell = pkgs.quickshell;
  };

  installedApps = lib.concatLists (
    lib.mapAttrsToList (name: defaultPackage:
      let
        app = cfg.apps.${name};
      in
      lib.optional (app.enable) (if app.package != null then app.package else defaultPackage)
    ) curatedApps
  );
in
{
  imports = [
    ./theming.nix
    ./bar.nix
  ];

  options.infernixos.desktop = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the infernixos user-level desktop environment: the curated set
        of home-manager applications, shell config and styling. Pairs with the
        system-level desktop module (greetd) for the full
        experience. Disabled by default so consumers can bring their own
        home setup.
      '';
    };

    shell.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable the infernixos default shell environment.";
    };

    apps = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = "Enable this application in the home environment.";
          };
          package = mkOption {
            type = types.nullOr types.package;
            default = null;
            description = "Override the package for this application.";
          };
        };
      });
      default = { };
      description = ''
        Granular per-application toggles. Each curated key installs its themed
        package when set to true; override `package` to substitute a different
        build. Curated applications: pyre (PySide6+QML file manager), fuzzel
        (launcher), kitty (terminal), quickshell (status bar).
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      home.packages = with pkgs; [
        htop
        ripgrep
        fd
        jq
        git
        nh
      ] ++ installedApps;

      home.sessionVariables = {
        EDITOR = "nano";
      };
    }

    (mkIf cfg.shell.enable {
      programs.bash.enable = true;
    })
  ]);
}
