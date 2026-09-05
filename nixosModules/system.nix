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
      default = true;
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

    hermesEnable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Run the Hermes Agent gateway as a system service. The agent runs as the
        `hermes` system user with full privileges and no sudo prompts, so the
        gateway is up regardless of which user is logged in.
      '';
    };

    hermesSettings = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      description = ''
        Hermes Agent settings, deep-merged into `services.hermes-agent.settings`
        (rendered as config.yaml). Consumers must set the model provider here.
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
        Login accounts granted the `hermes` group so their Hermes desktop/CLI
        clients can read the gateway state in /var/lib/hermes/.hermes.
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
        user = "hermes";
        group = "hermes";
        addToSystemPackages = true;
        settings = config.infernixos.system.hermesSettings;
      };

      users.users.hermes = {
        isSystemUser = true;
        group = "hermes";
        home = "/var/lib/hermes";
        createHome = true;
      };
      users.groups.hermes = { };

      assertions = [
        {
          assertion = config.infernixos.desktop.enable -> config.infernixos.desktop.hermesClientUsers != [ ];
          message = "infernixos.desktop.enable requires infernixos.desktop.hermesClientUsers so desktop users can read the gateway state.";
        }
      ];

      systemd.services.hermes-agent.environment.HERMES_HOME_MODE = "2770";
    })

    (mkIf config.infernixos.desktop.enable {
      programs.regreet.enable = true;
      programs.niri.enable = true;

      users.users = lib.listToAttrs (map
        (name: lib.nameValuePair name {
          extraGroups = [ "hermes" ];
        })
        config.infernixos.desktop.hermesClientUsers);
    })
  ];
}
