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
  options.infernixos.desktop.hermes = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable Hermes-first desktop integration: the Quickshell bar reads the
        gateway's own gateway_state.json for live status, a systemd-coredump
        path unit hands crashes to the gateway for diagnosis, and the
        diagnose-crash agent skill ships in $HERMES_HOME/skills. The gateway
        itself (services.hermes-agent) is wired by the consumer, not here;
        set `hermesStateFile` to the gateway's state JSON.
      '';
    };

    hermesPackage = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = "The hermes CLI package (runs `hermes chat` for crash diagnosis).";
    };

    hermesStateFile = mkOption {
      type = types.str;
      description = ''
        Absolute path of the gateway's gateway_state.json (default gateway
        layout: $HERMES_HOME/gateway_state.json).
      '';
    };

    hermesHome = mkOption {
      type = types.str;
      default = "/var/lib/hermes/.hermes";
      description = "The gateway's HERMES_HOME, which owns skills/.";
    };
  };

  config = mkIf config.infernixos.desktop.hermes.enable {
    assertions = [
      {
        assertion = config.infernixos.desktop.hermes.hermesPackage != null;
        message = "infernixos.desktop.hermes.enable requires hermesPackage (the hermes CLI that runs the gateway).";
      }
    ];

    # Crash diagnosis: a systemd path unit watches the coredump storage dir
    # (one file per crash, NixOS default storage=external). Each new file
    # starts this oneshot, which hands the newest coredump to the gateway.
    systemd.user.paths.hermes-crash-watch = {
      Unit.Description = "Watch for new coredumps to trigger Hermes diagnosis";
      Path = {
        PathExistsGlob = "/var/lib/systemd/coredump/*";
      };
      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.services.hermes-crash-diagnose = {
      Unit.Description = "Hand the newest systemd-coredump entry to Hermes for diagnosis";
      Service = {
        Type = "oneshot";
        ExecStart = let
          hermesCli = config.infernixos.desktop.hermes.hermesPackage;
          script = pkgs.writeShellScript "hermes-crash-diagnose" ''
            set -euo pipefail
            pid="$(${pkgs.systemd}/bin/coredumpctl list --no-legend 2>/dev/null | ${pkgs.coreutils}/bin/tail -1 | ${pkgs.gawk}/bin/awk '{print $5}')"
            [ -n "$pid" ] || exit 0
            exec ${hermesCli}/bin/hermes chat -q "Diagnose the crash for PID $pid using the diagnose-crash skill: run coredumpctl info $pid, read the backtrace, and tell me what failed and whether it is worth reporting upstream."
          '';
        in "${script}";
      };
    };

    home.file."${config.infernixos.desktop.hermes.hermesHome}/skills/diagnose-crash/SKILL.md".text = ''
      ---
      name: diagnose-crash
      description: Diagnose a crashed process from its systemd-coredump entry.
      ---

      # diagnose-crash

      Given a PID (or `latest`), establish the facts and judge severity.

      1. `coredumpctl info <pid>` — read the signal, executable, and stack trace.
      2. Identify the failing frame. If symbols are missing, note it; do not guess.
      3. Classify: app bug / environment issue / resource exhaustion.
      4. Recommend: restart, workaround, or report upstream. Only suggest filing
         an issue after checking for duplicates, and only with the user's agreement.
    '';
  };
}
