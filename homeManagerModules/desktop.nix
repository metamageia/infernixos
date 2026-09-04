{
  config,
  lib,
  pkgs,
  inputs,
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
    inputs.zen-browser.homeModules.default
    ./theming.nix
    ./bar.nix
    ./hermes.nix
  ];

  options.infernixos.desktop = {
    enable = mkOption {
      type = types.bool;
      default = true;
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
            default = true;
            description = "Enable this application in the home environment.";
          };
          package = mkOption {
            type = types.nullOr types.package;
            default = null;
            description = "Override the package for this application.";
          };
        };
      });
      default = {
        pyre.enable = true;
        fuzzel.enable = true;
        kitty.enable = true;
        niri.enable = true;
        quickshell.enable = true;
      };
      description = ''
        Granular per-application toggles for the curated set (pyre, fuzzel,
        kitty, niri, quickshell). Override `package` to substitute a
        different build.
      '';
    };

    zen.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable the zen-browser home-manager module (profile management, Sine).";
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
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
    })

    (mkIf cfg.zen.enable {
      programs.zen-browser = {
        enable = true;
        profiles.default = {
          settings = {
            "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
            "sine.allow-unsafe-js" = true;
            "zen.widget.linux.transparency" = true;
            "zen.urlbar.open-on-startup" = false;
          };
          sine = {
            enable = true;
            mods = [ ];
          };
        };
      };
    })

    (mkIf cfg.shell.enable {
      programs.bash.enable = true;
    })
  ];
}
