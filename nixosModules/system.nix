{
  config,
  options,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkMerge mkOption types;
  cfg = config.infernixos.system;

  tokenPath = "${config.services.hermes-agent.stateDir}/.hermes/backend-session-token";
  apiKeyPath = "${config.services.hermes-agent.stateDir}/.hermes/api-server-key";
  apiKeyEnvPath = "${config.services.hermes-agent.stateDir}/.hermes/api-server-key.env";
in {
  options.infernixos.system = with lib; {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable the infernixos system-level essentials: the curated core
        packages and the Hermes Agent gateway service. Off leaves the distro
        inert until a consumer opts in.
      '';
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [];
      description = ''
        Additional non-GUI system packages to install alongside the curated core
        essentials when `infernixos.system.enable` is true. GUI applications live
        in the home-manager desktop module instead.
      '';
    };

    hermesUser = mkOption {
      type = types.str;
      default = "hermes";
      description = ''
        Account the Hermes gateway/backend service runs as. Set it to the
        login user so the state tree in stateDir is owned by the same account
        that runs the Hermes desktop client — no shared-group permission
        drift. Defaults to a dedicated `hermes` system user.
      '';
    };

    hermesEnable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Run the Hermes Agent gateway and backend as system services as the
        non-root `hermes` user, sandboxed (NoNewPrivileges, ProtectSystem=strict,
        PrivateTmp). The gateway is up regardless of which user is logged in.
      '';
    };

    hermesBackendPort = mkOption {
      type = types.port;
      default = 9119;
      description = ''
        Loopback port of the Hermes backend (`hermes serve`) that the Hermes
        desktop client connects to with a session token. The backend binds to
        127.0.0.1 only.
      '';
    };

    hermesApiServerPort = mkOption {
      type = types.port;
      default = 8642;
      description = ''
        Loopback port of the gateway's API server (OpenAI-compatible session
        chat) used by the Quickshell bar HUD client. Binds to 127.0.0.1 only.
      '';
    };

    configRepo = mkOption {
      type = types.nullOr types.str;
      default = config.programs.nh.flake;
      defaultText = lib.literalExpression "config.programs.nh.flake";
      example = "/home/alice/nixos";
      description = ''
        Absolute path to the user's NixOS flake repo. Hermes edits and commits
        here, then requests a rebuild of a pinned commit that a logged-in wheel
        user approves from the bar. Defaults to `programs.nh.flake`, so the
        repo path is declared once. Null disables agent rebuilds. The repo must
        be group-writable by the users group so the hermes service can commit.
      '';
    };

    configHost = mkOption {
      type = types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "nixosConfigurations attribute in configRepo to build.";
    };

    hermesSettings = mkOption {
      type = types.attrsOf types.anything;
      default = {};
      description = ''
        Hermes Agent settings, deep-merged into `services.hermes-agent.settings`
        (rendered as config.yaml). Consumers must set the model provider here.
        Secrets never go here; use `services.hermes-agent.environmentFiles`.
      '';
    };
  };

  options.infernixos.desktop = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the infernixos desktop: the regreet GUI greeter and the niri
        compositor. Off by default so headless/core installations stay
        headless; a graphical consumer enables this explicitly.
      '';
    };

    hermesClientUsers = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        Login accounts that use the Hermes desktop client. They join the
        `hermes` service group so their clients can read the gateway state in
        the Hermes state directory and the seeded backend session token.
      '';
    };
  };

  config = mkMerge [
    (mkIf config.infernixos.system.enable {
      environment.systemPackages = with pkgs;
        [
          curl
          fd
          git
          gnupg
          jq
          ripgrep
          tmux
          wget
        ]
        ++ config.infernixos.system.extraPackages;
      programs.nh.enable = lib.mkDefault true;
    })

    (mkIf (config.infernixos.system.enable && config.infernixos.system.hermesEnable) {
      services.hermes-agent = {
        enable = true;
        package = lib.mkDefault (options.services.hermes-agent.package.default.overrideAttrs (old: {
          postInstall =
            (old.postInstall or "")
            + ''
              skills=$out/share/hermes-agent/skills
              orig=$(readlink -f $skills)
              rm $skills
              mkdir -p $skills
              cp -rs $orig/. $skills/
              chmod -R u+w $skills
              cp -rs ${../skills}/. $skills/
            '';
        }));
        user = cfg.hermesUser;
        createUser = cfg.hermesUser == "hermes";
        group = "users";
        addToSystemPackages = true;
        settings =
          lib.recursiveUpdate
          (lib.optionalAttrs config.infernixos.desktop.enable {
            display.skin = "wallust";
          })
          config.infernixos.system.hermesSettings;

        backend = {
          mode = "serve";
          host = "127.0.0.1";
          port = config.infernixos.system.hermesBackendPort;
          sessionTokenFile = tokenPath;
        };

        environment.API_SERVER_ENABLED = mkIf config.infernixos.system.hermesEnable "true";
        environment.API_SERVER_PORT = toString config.infernixos.system.hermesApiServerPort;
        environmentFiles = [apiKeyEnvPath];
      };

      systemd.services.hermes-agent.environment.HERMES_HOME_MODE = "2770";

      systemd.services.hermes-agent.serviceConfig.NoNewPrivileges =
        lib.mkIf (cfg.hermesUser != "hermes") (lib.mkForce false);

      systemd.services.hermes-agent.environment.HOME =
        lib.mkIf (cfg.hermesUser != "hermes") (lib.mkForce
          "/home/${cfg.hermesUser}");

      systemd.services.hermes-agent = {
        preStart = ''
          uid=$(id -u ${cfg.hermesUser})
          printf 'XDG_RUNTIME_DIR=/run/user/%s\nDBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%s/bus\n' "$uid" "$uid" \
            > /run/hermes-agent/userbus.env
        '';
        serviceConfig = {
          EnvironmentFile = "-/run/hermes-agent/userbus.env";
          RuntimeDirectory = "hermes-agent";
        };
      };

      systemd.services.hermes-agent.serviceConfig.ReadWritePaths =
        lib.mkIf (cfg.hermesUser != "hermes") ["/home/${cfg.hermesUser}"];

      systemd.services.hermes-backend = {
        preStart = ''
          mkdir -p "$(dirname "${tokenPath}")"
          if [ ! -s "${tokenPath}" ]; then
            umask 037
            ${pkgs.coreutils}/bin/head -c 32 /dev/urandom \
              | ${pkgs.coreutils}/bin/base64 | ${pkgs.coreutils}/bin/tr -d '\n' \
              > "${tokenPath}"
          fi
        '';
      };

      system.activationScripts."hermes-api-server-key" = {
        deps = ["users"];
        text = ''
          mkdir -p "$(dirname "${apiKeyPath}")"
          if [ ! -s "${apiKeyPath}" ]; then
            umask 037
            ${pkgs.coreutils}/bin/head -c 32 /dev/urandom \
              | ${pkgs.coreutils}/bin/base64 | ${pkgs.coreutils}/bin/tr -d '\n' \
              > "${apiKeyPath}"
          fi
          printf 'API_SERVER_KEY=%s\n' "$(cat "${apiKeyPath}")" > "${apiKeyEnvPath}"
        '';
      };

      system.activationScripts."hermes-agent-setup".deps = ["hermes-api-server-key"];

      environment.pathsToLink = [
        "/share/applications"
        "/share/xdg-desktop-portal"
        "/share/icons"
      ];

      assertions = [
        {
          assertion = config.infernixos.desktop.enable -> config.infernixos.desktop.hermesClientUsers != [];
          message = "infernixos.desktop.enable requires infernixos.desktop.hermesClientUsers so desktop users can use the Hermes client.";
        }
        {
          assertion = config.infernixos.system.hermesEnable -> config.infernixos.system.enable;
          message = "infernixos.system.hermesEnable requires infernixos.system.enable.";
        }
      ];
    })

    (mkIf (config.infernixos.system.enable && cfg.configRepo != null) {
      environment.sessionVariables.INFERNIXOS_CONFIG_REPO = cfg.configRepo;
      services.hermes-agent.environment.INFERNIXOS_CONFIG_REPO = cfg.configRepo;
      programs.git = {
        enable = true;
        config.safe.directory = cfg.configRepo;
      };
      systemd.services.hermes-agent.serviceConfig.ReadWritePaths = [cfg.configRepo];

      systemd.services."infernixos-rebuild@" = {
        description = "infernixos approved rebuild of %i";
        path = [config.system.build.nixos-rebuild config.nix.package pkgs.git];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.writeShellScript "infernixos-rebuild" ''
            set -eu
            case "$1" in
              *[!0-9a-f]*) echo "invalid rev" >&2; exit 2 ;;
            esac
            exec nixos-rebuild switch --flake "git+file://${cfg.configRepo}?rev=$1#${cfg.configHost}"
          ''} %i";
        };
      };

      security.polkit.enable = true;
      security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units"
              && action.lookup("verb") == "start"
              && action.lookup("unit").indexOf("infernixos-rebuild@") == 0
              && subject.local && subject.active
              && subject.isInGroup("wheel")${lib.optionalString (cfg.hermesUser == "hermes") ''

          && subject.user != "hermes"''}) {
            return polkit.Result.YES;
          }
        });
      '';

      assertions = [
        {
          assertion = lib.hasPrefix "/" cfg.configRepo;
          message = "infernixos.system.configRepo must be an absolute path.";
        }
      ];
    })

    (mkIf config.infernixos.desktop.enable {
      services.displayManager.regreet.enable = true;
      programs.niri.enable = true;

      users.users = lib.listToAttrs (map
        (name:
          lib.nameValuePair name {
            extraGroups = lib.optionals (config.infernixos.system.hermesUser != name) ["hermes"];
          })
        config.infernixos.desktop.hermesClientUsers);
    })
  ];
}
