{
  description = "infernixos — Hermes-first NixOS distro";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    hermes-agent = {
      url = "github:NousResearch/hermes-agent";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      hermes-agent,
      home-manager,
      ...
    }:
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
        desktop = import ./homeManagerModules/desktop.nix;
      };

      nixosConfigurations.infernixos = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit hermes-agent;
        };
        modules = [
          self.nixosModules.system
        ];
      };
    };
}
