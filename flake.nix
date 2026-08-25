{
  description = "hermetixos — bare-minimum NixOS flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hermes-agent = {
      url = "github:NousResearch/hermes-agent";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      hermes-agent,
      ...
    }:
    {
      nixosConfigurations.hermetixos = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          hermes-agent.nixosModules.default
          home-manager.nixosModules.home-manager
        ];
      };
    };
}
