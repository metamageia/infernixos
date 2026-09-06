{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkIf mkMerge mkOption types;
  cfg = config.infernixos.system;

  # Token lives outside the store: /var/lib/hermes is ReadWritePaths of the
  # service, and the hermes group is the client group — desktop client users
  # join it via infernixos.desktop.hermesClientUsers.
  tokenPath = "${config.services.hermes-agent.stateDir}/.hermes/backend-session-token";
  # Bearer key for the gateway's API server (bar HUD client + local frontends).
  # Same runtime-file treatment as the token so bar clients in the hermes group
  # can read it without it ever landing in the Nix store.
  apiKeyPath = "${config.services.hermes-agent.stateDir}/.hermes/api-server-key";
in
{
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
      default = [ ];
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

    hermesSettings = mkOption {
      type = types.attrsOf types.anything;
      default = { };
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
      default = [ ];
      description = ''
        Login accounts that use the Hermes desktop client. They join the
        `hermes` service group so their clients can read the gateway state in
        the Hermes state directory and the seeded backend session token.
      '';
    };
  };

  config = mkMerge [
    (mkIf config.infernixos.system.enable {
      environment.systemPackages = with pkgs; [
        curl
        fd
        git
        gnupg
        jq
        nh
        ripgrep
        tmux
        wget
      ] ++ config.infernixos.system.extraPackages;
    })

    (mkIf (config.infernixos.system.enable && config.infernixos.system.hermesEnable) {
      services.hermes-agent = {
        enable = true;
        user = cfg.hermesUser;
        # Upstream's createUser declares a system user with isSystemUser; wrong
        # when hermesUser is a login user (collides with isNormalUser).
        createUser = cfg.hermesUser == "hermes";
        group = "users";
        addToSystemPackages = true;
        settings = config.infernixos.system.hermesSettings;

        # Authenticated loopback backend for the desktop client. The token is
        # a fixed runtime file so the desktop can reconnect across backend
        # restarts; the server reads it at each start
        # (web_server.py: _resolve_session_token -> HERMES_DASHBOARD_SESSION_TOKEN).
        backend = {
          mode = "serve";
          host = "127.0.0.1";
          port = config.infernixos.system.hermesBackendPort;
          sessionTokenFile = tokenPath;
        };

        # Quickshell bar HUD client: the gateway's OpenAI-compatible API server
        # (gateway/platforms/api_server.py, default port 8642) exposes the
        # session-chat endpoints the bar talks to. The key itself is seeded to
        # the runtime api-server-key file below; this flag only turns the
        # platform on. Disabled entirely when the gateway is off.
        environment.API_SERVER_ENABLED = mkIf config.infernixos.system.hermesEnable "true";
        environment.API_SERVER_PORT = toString config.infernixos.system.hermesApiServerPort;
      };

      systemd.services.hermes-agent.environment.HERMES_HOME_MODE = "2770";

      # Seed the backend session token exactly once, only if absent, so a
      # token that exists survives rebuilds and is never regenerated behind a
      # connected client. The unit's preStart runs as the hermes service user
      # (never root); the file is 0640 hermes:hermes — readable by the service
      # and by desktop clients in the hermes group, never world-readable,
      # never in the Nix store.
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

      # Seed the API-server bearer key into .env exactly once (bar HUD client +
      # any local OpenAI-compat frontend). API_SERVER_KEY has no _FILE
      # indirection upstream, so the runtime file IS .env — writable, never in
      # the store. Same once-only pattern as the backend session token: survives
      # rebuilds, never regenerated behind a connected client.
      systemd.services.hermes-agent = {
        preStart = ''
          mkdir -p "$(dirname "${apiKeyPath}")"
          if [ ! -s "${apiKeyPath}" ]; then
            umask 037
            ${pkgs.coreutils}/bin/head -c 32 /dev/urandom \
              | ${pkgs.coreutils}/bin/base64 | ${pkgs.coreutils}/bin/tr -d '\n' \
              > "${apiKeyPath}"
          fi
          if ! ${pkgs.gnugrep}/bin/grep -q '^API_SERVER_KEY=' "$(dirname "${apiKeyPath}")/.env" 2>/dev/null; then
            printf 'API_SERVER_KEY=%s\n' "$(cat "${apiKeyPath}")" >> "$(dirname "${apiKeyPath}")/.env"
          fi
        '';
      };

      # Upstream HM demo requires these for xdg.portal desktop files and
      # portal D-Bus configs to resolve through home-manager paths.
      environment.pathsToLink = [
        "/share/applications"
        "/share/xdg-desktop-portal"
        "/share/icons"
      ];

      assertions = [
        {
          assertion = config.infernixos.desktop.enable -> config.infernixos.desktop.hermesClientUsers != [ ];
          message = "infernixos.desktop.enable requires infernixos.desktop.hermesClientUsers so desktop users can use the Hermes client.";
        }
        {
          assertion = config.infernixos.system.hermesEnable -> config.infernixos.system.enable;
          message = "infernixos.system.hermesEnable requires infernixos.system.enable.";
        }
      ];
    })

    (mkIf config.infernixos.desktop.enable {
      programs.regreet.enable = true;
      programs.niri.enable = true;

      users.users = lib.listToAttrs (map
        (name: lib.nameValuePair name {
          extraGroups = lib.optionals (config.infernixos.system.hermesUser != name) [ "hermes" ];
        })
        config.infernixos.desktop.hermesClientUsers);
    })
  ];
}
