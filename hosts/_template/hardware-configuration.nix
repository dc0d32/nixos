# Placeholder. Replaced per-host by `nixos-generate-config --show-hardware-config`
# via `nix run .#new-host -- <hostname>`.
{ ... }: {
  imports = [ ];
  # An empty fileSystems set will make nixos-rebuild fail until this file
  # is regenerated, which is intentional.
}
