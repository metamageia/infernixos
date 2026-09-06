{
  description = "infernixos — Hermes-first NixOS distro";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hermes-agent = {
      url = "github:NousResearch/hermes-agent/ad8f12f45b7e97cbac37f686724048837b14169b";
    };

    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # QML plugin exposing niri IPC to QuickShell (used by the bar).
    qml-niri = {
      url = "github:imiric/qml-niri";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputsOuter @ { flake-parts, ... }:
    flake-parts.lib.mkFlake { inputs = inputsOuter; } ({ inputs, ... }: {
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
          let
            inputs = {
              inherit (inputsOuter) zen-browser qml-niri hermes-agent;
            };
          in
          import ./homeManagerModules/desktop.nix (args // {
            inherit inputs;
            _module.args = { inherit inputs; };
          });

        nixosModules.default = inputs.self.flake.nixosModules.infernixos;
        homeManagerModules.default = inputs.self.flake.homeManagerModules.infernixos;

        # Isolated VM integration test (real pinned Hermes service). Heavy:
        # builds hermes-agent and boots a VM under KVM. Not part of checks.
        nixosTests.infernixos = import ./tests/vm-test.nix;
      };

      perSystem = { self', pkgs, ... }: {
        packages = rec {
          pyre = pkgs.callPackage ./packages/pyre/package.nix { };
          default = pyre;
        };

        checks = import ./tests/checks.nix {
          inherit inputs pkgs;
          self = inputs.self;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            python3
            uv
            git
            jq
            nixpkgs-fmt
          ];
        };
      };
    });
}
