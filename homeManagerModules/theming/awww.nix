{
  config,
  pkgs,
  ...
}: let
  wallustStateFile = "${config.xdg.configHome}/wallust/last-wallpaper";
in {
  home.packages = with pkgs; [awww];

  systemd.user.services.awww = {
    Unit = {
      Description = "Start awww daemon";
      After = ["graphical-session.target"];
      Requisite = ["graphical-session.target"];
      PartOf = ["graphical-session.target"];
    };
    Service = {
      ExecStart = "${pkgs.awww}/bin/awww-daemon --format xrgb";
      Restart = "on-failure";
    };
    Install = {
      WantedBy = ["graphical-session.target"];
    };
  };

  systemd.user.services.awww-wallpaper = {
    Unit = {
      Description = "Set initial wallpaper using awww";
      After = ["awww.service" "graphical-session.target"];
      Wants = ["awww.service"];
      Requisite = ["graphical-session.target"];
      PartOf = ["graphical-session.target"];
    };
    Service = {
      ExecStart = "${pkgs.bash}/bin/bash -c 'if [ -f \"${wallustStateFile}\" ]; then ${pkgs.awww}/bin/awww img \"$(cat \"${wallustStateFile}\")\" --transition-type center; fi'";
      Restart = "on-failure";
    };
    Install = {
      WantedBy = ["graphical-session.target"];
    };
  };
}
