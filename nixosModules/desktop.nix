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
        Enable the SDDM display manager, which presents the login screen and
        launches the user's compositor session (default: niri). GUI apps such
        as niri and fuzzel are provided by the home-manager module, not here.
      '';
    };

    session = mkOption {
      type = types.str;
      default = "niri";
      description = "The compositor session SDDM launches by default.";
    };
  };

  config = mkIf config.infernixos.desktop.enable {
    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
    };

    services.displayManager.defaultSession = config.infernixos.desktop.session;

    environment.systemPackages = with pkgs; [
      (pkgs.writeTextDir "share/wayland-sessions/${config.infernixos.desktop.session}.desktop" ''
        [Desktop Entry]
        Name=${config.infernixos.desktop.session}
        Comment=${config.infernixos.desktop.session} compositor session
        Exec=${pkgs.niri}/bin/${config.infernixos.desktop.session}-session
        Type=Application
      '')
    ];
  };
}