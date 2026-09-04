{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkIf mkMerge mkOption types;
in
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

    hermesCrashHook = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Wire systemd-coredump to notify the primary user's manager on any
        crash, where the hermes-crash-diagnose user path unit (home-manager
        module, infernixos.desktop.hermes.enable) picks it up and hands the
        coredump to Hermes. Requires exactly one graphical user; set
        `infernixos.system.primaryUser` to their name.
      '';
    };

    primaryUser = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "User whose manager receives crash-diagnosis triggers.";
    };
  };

  config = mkMerge [
    (mkIf config.infernixos.system.enable {
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
    })

    (mkIf config.infernixos.system.hermesCrashHook {
      assertions = [
        {
          assertion = config.infernixos.system.primaryUser != null;
          message = "infernixos.system.hermesCrashHook requires infernixos.system.primaryUser.";
        }
      ];

      # A coredump@ unit instance completes after every crash. The simplest
      # robust wiring is a systemd path unit watching the coredump
      # storage dir (default /var/lib/systemd/coredump), which gains a file
      # per crash when storage=external (the NixOS default).
      systemd.paths.hermes-crash-watch = {
        description = "Watch for new coredumps to trigger Hermes diagnosis";
        pathConfig = {
          PathExistsGlob = "/var/lib/systemd/coredump/*";
          # Trigger at most once per new file; the unit resets the watcher.
          Unit = "hermes-crash-relay.service";
          MakeDirectory = true;
        };
        wantedBy = [ "multi-user.target" ];
      };

      systemd.services.hermes-crash-relay = {
        description = "Relay a new coredump to the user's hermes-crash-diagnose unit";
        serviceConfig = {
          Type = "oneshot";
          TimeoutSec = 15;
        };
        # Fire-and-forget into the user's manager; never blocks, never fails
        # the boot if the user session is gone.
        script = ''
          user="${config.infernixos.system.primaryUser}"
          uid="$(id -u "$user" 2>/dev/null)" || exit 0
          [ -n "$uid" ] || exit 0
          runuser_out="$(mktemp)"
          if ${pkgs.util-linux}/bin/runuser -u "$user" -- \
            ${pkgs.systemd}/bin/systemctl --user start hermes-crash-diagnose.service \
            >"$runuser_out" 2>&1; then
            :
          fi
          rm -f "$runuser_out"
        '';
      };
    })
  ];
}
