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
  # Prefixed env file Hermes merges into .env (the raw key has no KEY= line).
  apiKeyEnvPath = "${config.services.hermes-agent.stateDir}/.hermes/api-server-key.env";
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
      # When the desktop is enabled, infernixos ships the wallust theming module
      # (homeManagerModules/desktop.nix → theming/wallust.nix) which renders the
      # Hermes skin YAML and deploys it to the gateway's skins dir. The gateway's
      # skin watcher (tui_gateway/server.py _skin_sig) polls display.skin from
      # config.yaml to decide which skins/<name>.yaml to watch — so the wallust
      # skin file is invisible to the live-reload watcher unless display.skin is
      # set to "wallust". Default it here when the desktop is enabled so the
      # theming pipeline is self-contained; a consumer who disables wallust
      # theming can override hermesSettings.display.skin to clear it.
      services.hermes-agent = {
        enable = true;
        user = cfg.hermesUser;
        # Upstream's createUser declares a system user with isSystemUser; wrong
        # when hermesUser is a login user (collides with isNormalUser).
        createUser = cfg.hermesUser == "hermes";
        group = "users";
        addToSystemPackages = true;
        settings = lib.recursiveUpdate
          (lib.optionalAttrs config.infernixos.desktop.enable {
            display.skin = "wallust";
          })
          config.infernixos.system.hermesSettings;

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
        # Key merged into .env by upstream activation (survives rebuilds).
        environmentFiles = [ apiKeyEnvPath ];
      };

      systemd.services.hermes-agent.environment.HERMES_HOME_MODE = "2770";

      # Upstream hardens the unit with NoNewPrivileges=true, which blocks
      # sudo in any shell spawned by the agent (the login user runs `nh os
      # switch` from the agent's terminal). Clear it when the gateway runs
      # as a login user; the NOPASSWD rule scopes what the agent may run.
      systemd.services.hermes-agent.serviceConfig.NoNewPrivileges =
        lib.mkIf (cfg.hermesUser != "hermes") (lib.mkForce false);

      # Upstream pins HOME to stateDir, which makes the agent believe its home
      # is the state directory. HERMES_HOME is set separately, so state still
      # resolves; but the agent's shell tool inherits HOME, so point it at the
      # login user's home so paths like ~/.config resolve correctly.
      systemd.services.hermes-agent.environment.HOME =
        lib.mkIf (cfg.hermesUser != "hermes") (lib.mkForce
          "/home/${cfg.hermesUser}");

      # The gateway runs as a system service but spawns restart-safe cron/kanban
      # workers via systemd-run --user --scope (process_registry.py fails closed
      # without it). That needs the user session bus, which a system service
      # does not get by default: without XDG_RUNTIME_DIR the user-bus probe
      # fails and every cron dispatch errors with "systemd-run --user --scope
      # is unavailable". Point it at the login user's runtime dir (linger is
      # enabled for hermesUser, so /run/user/<uid> exists even logged out).
      # ponytail: uid resolved via /etc/passwd at unit start, not eval time —
      # NixOS assigns UIDs during activation, so config.users.users.<n>.uid
      # is null at eval. ExecStartPre pins the value into a runtime env file.
      systemd.services.hermes-agent = {
        preStart = ''
          uid=$(id -u ${cfg.hermesUser})
          printf 'XDG_RUNTIME_DIR=/run/user/%s\nDBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%s/bus\n' "$uid" "$uid" \
            > /run/hermes-agent/userbus.env
        '';
        serviceConfig = {
          # Optional (`-`): on the first start of a boot the file doesn't exist
          # yet — preStart below writes it before ExecStart reads it.
          EnvironmentFile = "-/run/hermes-agent/userbus.env";
          # Owned by the service user, so preStart (non-root) can write into it.
          RuntimeDirectory = "hermes-agent";
        };
      };

      # Upstream's ReadWritePaths covers stateDir + workingDirectory only.
      # When the gateway runs as a login user, wallust-apply also writes to
      # ~/.config (templates, last-wallpaper), so add the login user's home.
      # Upstream already sets ProtectHome=false (read access to /home); this
      # adds the write path. Keep the stateDir too so the gateway can still
      # write its state tree.
      systemd.services.hermes-agent.serviceConfig.ReadWritePaths =
        lib.mkIf (cfg.hermesUser != "hermes") (lib.mkForce [
          config.services.hermes-agent.stateDir
          config.services.hermes-agent.workingDirectory
          "/home/${cfg.hermesUser}"
        ]);

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

      # Seed the API-server bearer key (bar HUD client + any local OpenAI-compat
      # frontend). Hermes regenerates $HERMES_HOME/.env from scratch on every
      # activation, so appending the key there (preStart) gets wiped. The key
      # therefore goes in via upstream's environmentFiles mechanism: an env file
      # (prefix line) is cat'd into .env on each activation.
      #   apiKeyPath     raw key  — read by the bar (no prefix).
      #   apiKeyEnvPath  API_SERVER_KEY=<key> — Hermes merges into .env.
      system.activationScripts."hermes-api-server-key" = {
        deps = [ "users" ];
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

      # Upstream's hermes-agent-setup writes .env from environmentFiles; make it
      # wait for our seed above so the key file is always present first.
      system.activationScripts."hermes-agent-setup".deps = [ "hermes-api-server-key" ];

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
