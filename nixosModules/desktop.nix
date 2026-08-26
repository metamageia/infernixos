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
  options.hermetixos.desktop = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the system-level graphical session glue: a lightweight greetd
        display manager that launches the user's Wayland session. This only
        wires the systemd service; the actual desktop/WM (e.g. niri) comes
        from the home-manager module.
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

  config = mkIf config.hermetixos.desktop.enable {
    services.greetd = {
      enable = true;
      settings = {
        default_session = {
          command = "${pkgs.niri}/bin/${config.hermetixos.desktop.session}";
          user = config.hermetixos.desktop.user;
        };
      };
    };
  };
}
