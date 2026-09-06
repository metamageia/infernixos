# Isolated NixOS VM integration test for infernixos.
#
# Exercised via `nix build .#nixosTests.infernixos.driver` (flake output) —
# never a public nixosConfigurations host. Boots the real pinned Hermes
# gateway + backend (`hermes serve`, session-token auth) as the non-root
# hermes user and verifies the authenticated loopback contract the desktop
# client depends on.
#
# NOTE: the runtime extension-execution slice (packages/runtime, executable
# `infernixos`) is owned by another worker and not yet exported; assertions
# about it are marked TODO-runtime and must not be mocked.
{ inputs }:
{ pkgs, lib, ... }:

{
  name = "infernixos-hermes-backend";
  hostPkgs = pkgs;

  nodes.machine = { ... }: {
    imports = [ inputs.self.nixosModules.infernixos ];

    virtualisation.graphics = false;

    infernixos.system.enable = true;
    infernixos.system.hermesEnable = true;
    infernixos.system.hermesBackendPort = 9119;
    infernixos.desktop.enable = true;
    infernixos.desktop.hermesClientUsers = [ "consumer" ];

    users.users.consumer = {
      isNormalUser = true;
      linger = true;
    };

    # TODO-runtime: packages/runtime/package.nix (executable `infernixos`)
    # will be added here as environment.systemPackages once the runtime
    # worker exports it; the activation/health assertions below depend on it.
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # Gateway is up as the non-root service user.
    machine.wait_for_unit("hermes-agent.service")
    machine.succeed("test \"$(systemctl show -p User --value hermes-agent.service)\" = hermes")

    # Backend binds loopback only.
    machine.wait_for_unit("hermes-backend.service")
    machine.succeed("ss -tln | grep 127.0.0.1:9119")
    machine.fail("ss -tln | grep 0.0.0.0:9119")

    # Session token was seeded exactly once, group-readable, never world-readable.
    token = machine.succeed("cat /var/lib/hermes/.hermes/backend-session-token").strip()
    assert token != "", "session token file is empty"
    mode = machine.succeed("stat -c '%a' /var/lib/hermes/.hermes/backend-session-token").strip()
    assert mode == "440", f"token mode is {mode}, expected 0440"

    # Unauthenticated request is refused; token-bearing request is accepted.
    machine.fail("curl -fsS http://127.0.0.1:9119/api/status")
    machine.succeed(f"curl -fsS -H 'Authorization: Bearer {token}' http://127.0.0.1:9119/api/status")

    # Token survives a backend restart (the desktop reconnection contract).
    machine.succeed("systemctl restart hermes-backend.service")
    machine.wait_for_unit("hermes-backend.service")
    token2 = machine.succeed("cat /var/lib/hermes/.hermes/backend-session-token").strip()
    assert token2 == token, "session token changed across backend restart"
    machine.succeed(f"curl -fsS -H 'Authorization: Bearer {token2}' http://127.0.0.1:9119/api/status")

    # Client user reads the token via the hermes group, exactly like the
    # desktop wrapper's extraRun does at launch.
    machine.succeed("sudo -u consumer cat /var/lib/hermes/.hermes/backend-session-token | grep -q .")

    # TODO-runtime: `infernixos` runtime helper present and its session-scoped
    # activation asks for polkit authorization (never NOPASSWD); health
    # commands run from immutable root-owned config only.
  '';
}
