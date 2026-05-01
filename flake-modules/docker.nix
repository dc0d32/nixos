# docker.nix — Docker daemon + compose CLI (NixOS).
#
# Why this module exists:
#   The homelab VM hosts (ah-N) are explicitly meant to run services
#   "usually through docker but not always". Packaging the daemon +
#   compose CLI as one dendritic NixOS module lets any future server
#   host opt in via `config.flake.modules.nixos.docker`, without
#   leaking a docker daemon into desktop hosts that don't need it.
#
# Why dockerd (not podman or oci-containers):
#   Per the host bridge's design questions, the user picked Docker
#   over podman (broadest compatibility with homelab tutorials,
#   compose stacks, and the docker-compose.yml ecosystem) and chose to
#   manage stacks externally as docker-compose files rather than
#   declaring containers as NixOS systemd units. That makes this
#   module a thin "enable the daemon and put the compose CLI on PATH"
#   primitive.
#
# Why add `users.primary` to the docker group:
#   Without group membership the user must `sudo docker …` for every
#   command, which is friction. Adding them to the docker group lets
#   them run docker as themselves -- BUT note: membership in the
#   docker group is effectively root on the host (the docker socket
#   trivially mounts host paths into containers as root). For a
#   single-admin homelab box this is the standard tradeoff; for a
#   multi-tenant box you'd want rootless docker or podman instead.
#   The module wires this off `config.users.primary` (declared by
#   flake-modules/users.nix) so the host bridge controls who that is.
#
# Why docker-compose in environment.systemPackages, not just docker:
#   nixpkgs ships docker-compose v2 (the Go CLI plugin) as its own
#   attribute. Installing it system-wide makes BOTH `docker compose`
#   (subcommand) and `docker-compose` (standalone wrapper) work
#   regardless of how the user invokes it.
#
# Retire when:
#   - All consumers move to podman / rootless docker / NixOS-managed
#     oci-containers, OR
#   - Replaced by a more opinionated container-host module that
#     bundles docker + compose + log rotation + storage-driver tuning
#     + iptables policy as a single primitive.
{
  flake.modules.nixos.docker = { config, pkgs, ... }: {
    virtualisation.docker.enable = true;

    # Compose v2 CLI. With this present, both `docker compose ...`
    # (subcommand resolved via the docker CLI plugin search path) and
    # the legacy `docker-compose ...` wrapper work.
    environment.systemPackages = [ pkgs.docker-compose ];

    # Let the primary user run docker without sudo. See header for
    # the security caveat (docker group ~= root on host).
    users.users.${config.users.primary}.extraGroups = [ "docker" ];
  };
}
