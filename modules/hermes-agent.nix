{
  config,
  lib,
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
      type = types.nullOr types.str;
      default = null;
      description = ''
        System user that runs the Hermes Agent gateway. Required when
        `hermetixos.agent.enable` is true. A consumer supplies its own value;
        no default user is assumed.
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
    assertions = [
      {
        assertion = config.hermetixos.agent.user != null;
        message = ''
          `hermetixos.agent.user` must be set (non-null) when
          `hermetixos.agent.enable` is true.
        '';
      }
    ];

    services.hermes-agent = {
      enable = true;
      user = config.hermetixos.agent.user;
      createUser = true; # distro owns the agent user; never assume a login user exists
      addToSystemPackages = true;
      settings = config.hermetixos.agent.settings;
    };
  };
}
