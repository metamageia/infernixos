{
  description = "infernixos — Hermes-first NixOS distro";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hermes-agent = {
      url = "github:NousResearch/hermes-agent/ad8f12f45b7e97cbac37f686724048837b14169b";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ { flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      flake = {
        nixosModules.infernixos = {
          imports = [
            inputs.hermes-agent.nixosModules.default
            ./nixosModules/system.nix
          ];
        };

        homeManagerModules.infernixos =
          args @ { config, lib, pkgs, ... }:
          import ./homeManagerModules/desktop.nix (args // {
            inputs = { inherit (inputs) zen-browser; };
          });

        nixosConfigurations.infernixos = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            inputs.self.nixosModules.infernixos
            inputs.home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.infernixos.imports = [ inputs.self.homeManagerModules.infernixos ];
              home-manager.users.infernixos.home.stateVersion = "25.05";
              users.users.infernixos = {
                isNormalUser = true;
                extraGroups = [ "wheel" ];
              };
              infernixos.system.primaryUser = "infernixos";
              home-manager.users.infernixos.infernixos.desktop.hermes.enable = false;
              # demo host: no hermes gateway package wired; consumers set it or disable
              # ponytail: throwaway demo host; consumers provide real hardware config
              fileSystems."/" = {
                device = "/dev/disk/by-label/infernixos";
                fsType = "ext4";
              };
              boot.loader.systemd-boot.enable = true;
              system.stateVersion = "25.05";
            }
          ];
        };
      };

      perSystem = { self', pkgs, ... }: {
        packages = rec {
          pyre = pkgs.callPackage ./packages/pyre/package.nix { };
          default = pyre;
        };
      };
    };
}
