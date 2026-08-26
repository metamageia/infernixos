{
  description = "hermetixos — bare-minimum NixOS flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    hermes-agent = {
      url = "github:NousResearch/hermes-agent";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      hermes-agent,
      ...
    }:
    {
      nixosConfigurations.hermetixos = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {
          inherit hermes-agent;
        };
        modules = [
          ./modules/hermes-agent.nix
        ];
      };
    };
}
