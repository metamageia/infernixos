{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkIf mkOption mkMerge types;
in
{
  options.hermetixos.desktop = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the hermetixos user-level desktop environment: the curated set
        of home-manager applications, shell config and styling. Pairs with the
        system-level desktop module (greetd + niri + fuzzel) for the full
        experience. Disabled by default so consumers can bring their own
        home setup.
      '';
    };

    shell.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable the hermetixos default shell environment.";
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
        Granular per-application toggles. Each key enables a curated
        application when set to true. Override `package` to substitute a
        different package.
      '';
    };
  };

  config = mkIf config.hermetixos.desktop.enable (mkMerge [
    {
      home.packages = with pkgs; [
        htop
        ripgrep
        fd
        jq
        git
        nh
      ];

      home.sessionVariables = {
        EDITOR = "nano";
      };
    }

    (mkIf config.hermetixos.desktop.shell.enable {
      programs.bash.enable = true;
    })
  ]);
}
