{
  description = "hermetixos — Hermes-first NixOS distro";

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
    {
      nixosModules = {
        default = import ./nixosModules/agent.nix;
        agent = import ./nixosModules/agent.nix;
      };

      homeManagerModules = {
        default = import ./homeManagerModules/default.nix;
      };

      nixosConfigurations.hermetixos = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {
          inherit hermes-agent;
        };
        modules = [
          self.nixosModules.default
        ];
      };
    };
}
