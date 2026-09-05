{
  config,
  pkgs,
  ...
}: let
  # State file recording the last wallpaper chosen via wallust-switch. Read by the
  # awww-wallpaper service at session start so a rebuild/login restores the last
  # choice instead of resetting to the hardcoded default.
  wallustStateFile = "${config.xdg.configHome}/wallust/last-wallpaper";
in {
  home.packages = with pkgs; [awww];

  systemd.user.services.awww = {
    Unit = {
      Description = "Start awww daemon";
      # Match awww's upstream contrib unit: only start once the graphical
      # session (niri) is up, so WAYLAND_DISPLAY exists and the daemon can
      # connect. Without Requisite + graphical-session.target the daemon fired
      # at boot before the display socket existed, aborted (ABRT), and hit
      # systemd's start-limit after 6 tries — leaving no wallpaper. (08-29)
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
      # Wait for the daemon to be up, which itself waits for the graphical
      # session — so WAYLAND_DISPLAY is present when we call `awww img`.
      After = ["awww.service" "graphical-session.target"];
      Wants = ["awww.service"];
      Requisite = ["graphical-session.target"];
      PartOf = ["graphical-session.target"];
    };
    Service = {
      # Restore the last wallpaper chosen via wallust-switch (state file). No
      # hardcoded default — the old hardcoded wallpaper was removed (old rice).
      # If no choice is saved yet, awww simply keeps whatever it last displayed.
      ExecStart = "${pkgs.bash}/bin/bash -c 'if [ -f \"${wallustStateFile}\" ]; then ${pkgs.awww}/bin/awww img \"$(cat \"${wallustStateFile}\")\" --transition-type center; fi'";
      Restart = "on-failure";
    };
    Install = {
      WantedBy = ["graphical-session.target"];
    };
  };
}
