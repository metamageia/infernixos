{
  config,
  lib,
  pkgs,
  hermes-agent,
  ...
}:

{
  imports = [ hermes-agent.nixosModules.default ];

  options.hermetixos.agent = with lib; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to enable the Hermes Agent gateway on this system.
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
          hermetixos.agent.settings.model = "provider/model";
        and may add any other Hermes settings here.
      '';
    };
  };

  config = lib.mkIf config.hermetixos.agent.enable {
    services.hermes-agent = {
      enable = true;
      user = config.hermetixos.agent.user;
      group = config.hermetixos.agent.user;
      createUser = config.hermetixos.agent.user != "root";
      addToSystemPackages = true;
      settings = config.hermetixos.agent.settings;
    };
  };
}
