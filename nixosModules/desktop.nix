{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkIf mkOption types;
in
{
  options.infernixos.desktop = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the infernixos desktop experience: a lightweight greetd display
        manager launching the niri Wayland compositor, plus the curated set of
        user-facing applications (niri, fuzzel, and the base tool set).
      '';
    };

    user = mkOption {
      type = types.str;
      default = "root";
      description = "User the graphical session logs into by default.";
    };

    session = mkOption {
      type = types.str;
      default = "niri-session";
      description = "The Wayland session command to launch under greetd.";
    };
  };

  config = mkIf config.infernixos.desktop.enable {
    services.greetd = {
      enable = true;
      settings = {
        default_session = {
          command = "${pkgs.niri}/bin/${config.infernixos.desktop.session}";
          user = config.infernixos.desktop.user;
        };
      };
    };

    environment.systemPackages = with pkgs; [ niri fuzzel ];
  };
}
