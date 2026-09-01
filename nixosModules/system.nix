{
  config,
  lib,
  pkgs,
  hermes-agent,
  ...
}:

{
  imports = [ hermes-agent.nixosModules.default ];

  options.infernixos.system = with lib; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the Hermes Agent gateway on this system.
        Disabled by default so the distro is inert until a consumer opts in.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "root";
      description = ''
        System user that runs the Hermes Agent gateway. Defaults to `root`:
        the agent-first stance is that the agent runs with full privileges and
        never prompts for sudo. A consumer may override to a lesser-privileged
        user if they prefer.
      '';
    };

    settings = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      description = ''
        Hermes Agent configuration (deep-merged into `services.hermes-agent.settings`
        and rendered as config.yaml). Personal-fact-free by default.
        Consumers MUST set the model provider, e.g.:
          infernixos.system.settings.model = "provider/model";
        and may add any other Hermes settings here.
      '';
    };

    desktop = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Install the Hermes Desktop (Electron) application system-wide and point
          it at the shared agent backend. Every user, present or future, gets the
          desktop app and connects to the same gateway. A session token is
          auto-generated at activation into a world-readable runtime path.
        '';
      };

      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address the desktop uses to reach the agent backend.";
      };

      port = mkOption {
        type = types.port;
        default = 9119;
        description = "Port the desktop uses to reach the agent backend.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf config.infernixos.system.enable {
      services.hermes-agent = {
        enable = true;
        user = config.infernixos.system.user;
        group = config.infernixos.system.user;
        createUser = config.infernixos.system.user != "root";
        addToSystemPackages = true;
        settings = config.infernixos.system.settings;
      };
    })
    (lib.mkIf (config.infernixos.system.enable && config.infernixos.system.desktop.enable) (let
      desktopCfg = config.infernixos.system.desktop;
      tokenFile = "${config.services.hermes-agent.stateDir}/desktop-token";
      desktopPackage = (hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.desktop).override {
        extraEnv = {
          HERMES_DESKTOP_REMOTE_URL = "http://${desktopCfg.host}:${toString desktopCfg.port}";
        };
        extraRun = [
          ''
            if [ -r ${tokenFile} ]; then
              export HERMES_DESKTOP_REMOTE_TOKEN="$(tr -d '\r\n' < ${tokenFile})"
            fi
          ''
        ];
      };
    in {
      services.hermes-agent.backend = {
        mode = lib.mkDefault "serve";
        host = lib.mkDefault desktopCfg.host;
        port = lib.mkDefault desktopCfg.port;
        sessionTokenFile = tokenFile;
      };

      environment.systemPackages = [ desktopPackage ];

      system.activationScripts.infernixos-desktop-token = lib.stringAfter [ "users" ] ''
        token_file=${tokenFile}
        if [ ! -e "$token_file" ]; then
          ${pkgs.openssl}/bin/openssl rand -hex 32 > "$token_file"
        fi
        chmod 0644 "$token_file"
      '';
    }))
  ];
}
