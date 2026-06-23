# nix-ld — run unpatched, dynamically-linked "generic Linux" binaries
# on NixOS.
#
# NixOS ships no /lib64/ld-linux-x86-64.so.2; by default that path holds
# a *stub* loader whose only job is to print the "NixOS cannot run
# dynamically linked executables …" message (see nix.dev/permalink/
# stub-ld). Tools that drop a prebuilt binary into $HOME and exec it —
# most notably the VS Code Remote (WSL / SSH / Tunnels) server, whose
# bundled `node` lives at ~/.vscode-server/bin/<hash>/node — therefore
# fail to start.
#
# `programs.nix-ld.enable` replaces that stub with a real loader at the
# standard path, backed by a curated set of common libraries (glibc,
# libstdc++, zlib, openssl, …) baked into the wrapper. That is enough
# for the VS Code server's node to launch; most language servers and
# other downloaded dev binaries work for the same reason. If a specific
# binary needs a library not in the default set, a host can extend
# `programs.nix-ld.libraries` in its bridge.
#
# Pattern A: hosts opt in by importing this module. Currently imported
# by the WSL hosts (the VS Code Remote-WSL server is the motivating
# case); any host that needs to run unpatched binaries (e.g. a future
# Remote-SSH target) can import it too.
#
# Retire when: NixOS no longer needs to host prebuilt foreign binaries
#   (e.g. VS Code Remote stops shipping a dynamically-linked server, or
#   every such tool is consumed through a nix-built / FHS-wrapped path),
#   OR upstream makes the working loader the default.
{ ... }:
{
  flake.modules.nixos.nix-ld = {
    programs.nix-ld.enable = true;
  };
}
