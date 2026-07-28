# bin-bash — an FHS `/bin/bash` compatibility symlink.
#
# NixOS deliberately ships only `/bin/sh` and `/usr/bin/env`; every other
# interpreter is expected to be resolved through PATH. That is the right
# default, and this repo enforces it for its own scripts (AGENTS.md:
# always `#!/usr/bin/env bash`, never `#!/bin/bash`; the
# `check-bash-shebang` pre-commit hook and `nix flake check` reject it).
#
# Third-party binaries we do not control are another matter. The
# motivating case is the GitHub Copilot CLI: as of 1.0.61 its shell tool
# spawns the pty with a hardcoded literal, in the shell-session factory
# of lib/github-copilot-cli/sdk/index.js:
#
#     let u = l ? c : "/bin/bash", …            // l = isPowerShell
#     h = g(u, d, { cols: p, rows: m, cwd: r, env: { … } })
#
# There is no $SHELL fallback and no PATH lookup — that string is the
# only occurrence of "/bin/bash" in the package. On NixOS the node-pty
# spawn therefore fails, `this.process` is undefined, and every command
# the agent runs throws "Failed to start bash process", which makes the
# CLI useless as an agent. The nixpkgs wrapper prepends bash-interactive
# to PATH, which was enough for earlier releases and no longer is.
#
# So: create the symlink the same way nixpkgs itself creates `/bin/sh` —
# an atomic ln+mv inside an activation script, so it is re-established
# on every `nixos-rebuild switch` AND on every boot. The boot half
# matters here: hosts importing flake-modules/impermanence.nix roll `/`
# back to an empty subvol in initrd, so anything under /bin has to be
# recreated from scratch each time. `mkdir -p /bin` keeps this
# independent of upstream's `binsh` activation script rather than
# ordering against an internal name that may be renamed.
#
# This does NOT relax the repo's own shebang rule. `#!/bin/bash` would
# now work on hosts importing this module, but the pre-commit hook still
# rejects such a shebang before it can be committed, and a NixOS box
# without this module still would not run it.
#
# Pattern A: hosts opt in by importing. Imported by every NixOS host in
# this flake — via bundles/nixos-workstation.nix for pb-x1 / m-pc /
# pb-t480, directly by wsl / nixtest / ah-1 — because the Copilot CLI is
# used on all of them. pb-mb is macOS (userland-only, no NixOS config)
# and ships /bin/bash already.
#
# Retire when: the Copilot CLI (and any other offender) resolves bash
#   from PATH / $SHELL instead of hardcoding /bin/bash, OR this flake
#   stops running third-party agents that shell out to an absolute bash
#   path.
{ ... }:
{
  flake.modules.nixos.bin-bash = { pkgs, ... }: {
    system.activationScripts.binbash = {
      text = ''
        ${pkgs.coreutils}/bin/mkdir -p /bin
        ${pkgs.coreutils}/bin/ln -sfn ${pkgs.bashInteractive}/bin/bash /bin/.bash.tmp
        ${pkgs.coreutils}/bin/mv /bin/.bash.tmp /bin/bash
      '';
    };
  };
}
