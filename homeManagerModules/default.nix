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
  options.hermetixos.home = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the hermetixos curated home-manager environment. This is the
        "rice": a coherent set of user-level applications, shell config and
        styling layered on top of the system-level agentic OS. Disabled by
        default so consumers can bring their own DE/WM and home setup.
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

  config = mkIf config.hermetixos.home.enable (mkMerge [
    {
      home.packages = with pkgs; [
        htop
        ripgrep
        fd
        jq
        git
        niri
        fuzzel
        nh
      ];

      home.sessionVariables = {
        EDITOR = "nano";
      };
    }

    (mkIf config.hermetixos.home.shell.enable {
      programs.bash.enable = true;
    })
  ]);
}
