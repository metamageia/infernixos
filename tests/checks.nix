# Real module checks for infernixos.
#
# Evaluated by flake.nix perSystem checks. Each check evaluates the actual
# exported modules the way a consumer would (nixosSystem for NixOS,
# homeManagerConfiguration for HM). A wrong type, a missing option, a broken
# assertion or an insecure wiring fails the check instead of a rebuild.
{ inputs, pkgs, self }:

let
  lib = inputs.nixpkgs.lib;

  baseNixosModules = {
    system.stateVersion = "25.05";
    nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "/dev/null";
      fsType = "ext4";
    };
    users.users.consumer = {
      isNormalUser = true;
    };
  };

  evalNixos = configExtra:
    lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        self.nixosModules.infernixos
        baseNixosModules
        configExtra
      ];
    };

  evalHome = configExtra:
    inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        self.homeManagerModules.infernixos
        {
          home.username = "consumer";
          home.homeDirectory = "/home/consumer";
          home.stateVersion = "25.05";
        }
        configExtra
      ];
    };

  evals = {
    nixos-headless = evalNixos { };
    nixos-desktop = evalNixos {
      infernixos.desktop.enable = true;
      infernixos.desktop.hermesClientUsers = [ "consumer" ];
    };
    nixos-apps-disabled = evalNixos {
      infernixos.system.hermesEnable = false;
      infernixos.system.extraPackages = [ pkgs.hello ];
    };
    hm-desktop-defaults = evalHome { };
    hm-apps-disabled = evalHome {
      infernixos.desktop = {
        zen.enable = false;
        apps = lib.genAttrs
          [ "pyre" "fuzzel" "kitty" "quickshell" "vesktop" "hermesDesktop" ]
          (_: { enable = false; });
        theming = {
          wallust.enable = false;
          awww.enable = false;
          quickshell.enable = false;
          niri.enable = false;
        };
      };
    };
  };

  headlessCfg = evals.nixos-headless.config;
  desktopCfg = evals.nixos-desktop.config;

  assertBackendToken =
    headlessCfg.services.hermes-agent.backend == {
      mode = "serve";
      host = "127.0.0.1";
      port = 9119;
      sessionTokenFile = "${headlessCfg.services.hermes-agent.stateDir}/.hermes/backend-session-token";
    };

  assertNoSecretInStore =
    !(lib.hasPrefix builtins.storeDir headlessCfg.services.hermes-agent.backend.sessionTokenFile);

  assertSandbox =
    let sc = headlessCfg.systemd.services.hermes-agent.serviceConfig;
    in sc.NoNewPrivileges == true
    && sc.ProtectSystem == "strict"
    && sc.User == "hermes"
    && sc.User != "root";

  assertTokenSeededOnce =
    lib.hasInfix "if [ ! -s" headlessCfg.systemd.services.hermes-backend.preStart;

  assertDesktopUsesService =
    let pkg = builtins.elem desktopCfg.environment.systemPackages [];
    in desktopCfg.services.hermes-agent.backend.sessionTokenFile != null
    && desktopCfg.users.users ? consumer;

in
{
  nixos-headless = evals.nixos-headless.config.system.build.toplevel.drvPath != "";
  nixos-desktop = evals.nixos-desktop.config.system.build.toplevel.drvPath != "";
  nixos-apps-disabled = evals.nixos-apps-disabled.config.system.build.toplevel.drvPath != "";
  nixos-backend-token = assertBackendToken && assertNoSecretInStore && assertSandbox && assertTokenSeededOnce;
  hm-desktop-defaults = evals.hm-desktop-defaults.config.home.activationPackage.drvPath != "";
  hm-apps-disabled = evals.hm-apps-disabled.config.home.activationPackage.drvPath != "";
  no-legacy-outputs = !(self ? nixosConfigurations);
}
