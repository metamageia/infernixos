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
        Enable the infernixos system-level desktop components: a lightweight
        greetd display manager launching the configured Wayland session (niri).
        User-facing applications (niri, fuzzel) are provided by the
        home-manager desktop module.
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
  };
}
