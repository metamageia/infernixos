{
  description = "infernixos — Hermes-first NixOS distro";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      ...
    } @ inputs:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.${system}.pyre = pkgs.callPackage ./packages/pyre/package.nix { };

      nixosModules = {
        system = import ./nixosModules/system.nix;
        desktop = import ./nixosModules/desktop.nix;
      };

      homeManagerModules = {
        desktop = {
          config,
          lib,
          pkgs,
          ...
        }@args:
          import ./homeManagerModules/desktop.nix (args // { inherit inputs; });
      };

      nixosConfigurations.infernixos = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          self.nixosModules.system
        ];
      };
    };
}