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
    quickshell = pkgs.quickshell;
    vesktop = pkgs.vesktop;
    # Hermes desktop (Electron GUI) — mirrors dotfiles' install of
    # inputs.hermes-agent.packages.<system>.desktop.
    hermesDesktop = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.desktop;
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
    # infernixos dynamic theming engine (wallust) + the rice it drives.
    ./theming/wallust.nix
    ./theming/awww.nix
    ./theming/quickshell.nix
    ./theming/niri-home.nix
  ];

  options.infernixos.desktop = {
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
        quickshell.enable = true;
        vesktop.enable = true;
        hermesDesktop.enable = true;
      };
      description = ''
        Granular per-application toggles for the curated set (pyre, fuzzel,
        kitty, quickshell, vesktop, hermesDesktop). Override `package` to
        substitute a different build.
      '';
    };

    zen.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable the zen-browser home-manager module (profile management, Sine).";
    };

    theming = {
      wallpapersDir = mkOption {
        type = types.path;
        default = ../wallpapers;
        description = ''
          Directory of wallpapers (jpg/png/webp) the infernixos theming engine
          lists and applies. Bundled by default; point to your own set to
          replace it.
        '';
      };

      # Multi-dir wallpapers: distro defaults + user dirs. Consumers read
      # wallpaperDirs (final merged list). enableDefaults=false excludes the
      # infernixos-bundled set without touching user dirs.
      wallpaper.enableDefaults = mkOption {
        type = types.bool;
        default = true;
        description = "Include infernixos's bundled default wallpapers.";
      };

      wallpaper.extraDirs = mkOption {
        type = types.listOf types.path;
        default = [];
        description = ''
          Additional wallpaper directories (jpg/png/webp) to include alongside
          the defaults. All dirs end up as read-only store paths.
        '';
      };

      wallpaper.dirs = mkOption {
        type = types.listOf types.path;
        readOnly = true;
        description = "Final merged wallpaper directory list (read this).";
      };

      hermesSkinsDir = mkOption {
        type = types.str;
        default = "/var/lib/hermes/.hermes/skins";
        description = ''
          Directory the Hermes desktop skin is written to. Defaults to the
          gateway's skins dir; override for a non-standard HERMES_HOME.
        '';
      };

      zenProfileDir = mkOption {
        type = types.str;
        default = "e06yfgug.Default Profile";
        description = ''
          On-disk Zen profile dir (the hash varies per machine). wallust writes
          chrome/userChrome.css here. Set to your profile dir if yours differs.
        '';
      };
    };
  };

  config = mkMerge [
    {
      # Expose flake inputs to imported theming submodules (quickshell needs qml-niri).
      _module.args = { inherit inputs; };

      infernixos.desktop.theming.wallpaper.dirs =
        (lib.optionals cfg.theming.wallpaper.enableDefaults [ cfg.theming.wallpapersDir ])
        ++ cfg.theming.wallpaper.extraDirs;

      home.packages = installedApps;

      home.sessionVariables = {
        EDITOR = "nano";
        HERMES_GATEWAY_MODE = "connect";
      };
    }

    (mkIf cfg.zen.enable {
      programs.zen-browser = {
        enable = true;
        profiles.default = {
          # Adopt the existing on-disk profile (regenerates profiles.ini).
          name = "Default Profile";
          path = cfg.theming.zenProfileDir;
          settings = {
            "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
            "sine.allow-unsafe-js" = true;
            "zen.widget.linux.transparency" = true;
            "zen.urlbar.open-on-startup" = false;
          };
          # sine.enable with EMPTY mods installs only the bootloader that
          # scans chrome/sine-mods/mods.json; the wallust-reloader is a
          # LOCAL mod registered there (see home.file below).
          sine = {
            enable = true;
            mods = [ ];
          };
        };
      };

      # Live-reload watcher for wallust-driven userChrome.css, as a local
      # sine mod (matches ~/.dotfiles modules/zen).
      home.file."${config.xdg.configHome}/zen/${cfg.theming.zenProfileDir}/chrome/sine-mods/mods.json".text = ''
        {
          "wallust-reloader": {
            "id": "wallust-reloader",
            "enabled": true,
            "origin": "local",
            "scripts": {
              "wallust-reloader.uc.js": {}
            }
          }
        }
      '';

      home.file."${config.xdg.configHome}/zen/${cfg.theming.zenProfileDir}/chrome/sine-mods/wallust-reloader/wallust-reloader.uc.js".text = ''
        // ==UserScript==
        // @name         Wallust Zen theme reloader
        // @namespace    local.wallust
        // @description  Live-reload userChrome.css when wallust rewrites it.
        // @version      1.0
        // @include      *
        // ==/UserScript==
        (function () {
          "use strict";
          const file = Services.dirsvc.get("UChrm", Ci.nsIFile)
            .QueryInterface(Ci.nsIFile);
          file.append("userChrome.css");
          if (!file.exists() || !file.isFile()) return;
          let last = file.lastModifiedTime;
          const sss = Cc["@mozilla.org/content/style-sheet-service;1"]
            .getService(Ci.nsIStyleSheetService);
          setInterval(() => {
            try {
              const fresh = file.clone();
              if (fresh.exists() && fresh.lastModifiedTime > last) {
                last = fresh.lastModifiedTime;
                const uri = Services.io.newFileURI(fresh);
                [sss.USER_SHEET, sss.AGENT_SHEET].forEach((t) => {
                  if (sss.sheetRegistered(uri, t)) sss.unregisterSheet(uri, t);
                  sss.loadAndRegisterSheet(uri, t);
                });
                Services.obs.notifyObservers(null, "chrome-flush-caches", null);
              }
            } catch (e) { /* ignore */ }
          }, 1000);
        })();
      '';
    })

    (mkIf cfg.shell.enable {
      programs.bash.enable = true;
    })
  ];
}
