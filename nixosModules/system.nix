{
  config,
  lib,
  pkgs,
  ...
}:

{
  options.infernixos.system = with lib; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the infernixos system-level essentials: the curated core
        packages. Disabled by default so the distro is inert until a consumer
        opts in.
      '';
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = ''
        Additional non-GUI system packages to install alongside the curated core
        essentials when `infernixos.system.enable` is true. GUI applications live
        in the home-manager desktop module instead.
      '';
    };
  };

  config = lib.mkIf config.infernixos.system.enable {
    environment.systemPackages = with pkgs; [
      curl
      git
      gnupg
      jq
      ripgrep
      tmux
      vim
      wget
    ] ++ config.infernixos.system.extraPackages;
  };
}