# fish — alternative interactive shell.
#
# homeManager-class only. The system-wide enable
# (`programs.fish.enable = true`, which adds fish to /etc/shells and
# wires the vendor-completions hook) is set in flake-modules/users.nix
# alongside the matching zsh enable, since every host in this flake
# wants both shells available.
#
# This module provides the HM-side fish configuration:
#   - sane interactive defaults
#   - nr / hm rebuild helpers, ported from zsh.nix and translated to
#     fish syntax (including the WSL host-detection logic that picks
#     wsl/wsl-arm by uname -m on /proc/sys/kernel/osrelease=Microsoft)
#   - aliases (ls/git) and fish abbreviations (visually expanding
#     command shortcuts — fish-idiomatic equivalent of aliases)
#   - flips on enableFishIntegration for the same companion tools
#     zsh.nix wires up (starship, fzf, zoxide, eza, dircolors, direnv)
#     so fish hosts have feature parity with zsh hosts.
#
# Pattern A: every account in this flake imports this via the
# home-base / home-kid bundles, so fish is INSTALLED and configured
# on every host even though zsh is the default login shell. To make
# fish the actual login shell on a given host, set
#   users.users.<u>.shell = pkgs.fish;
# in that host's NixOS module. (A flake-wide flip to fish was tried
# in 2026-05 and reverted; this module survived the revert so the
# switch stays a one-liner.)
#
# Coexistence with zsh: by design, this module does NOT disable zsh,
# and the base bundle keeps shipping zsh as the default. Both shells
# stay in PATH for any tooling that invokes either explicitly.
#
# Retire when: the user picks one shell project-wide and deletes
#   the loser's HM module + bundle entry, OR fish disappears from
#   nixpkgs (won't happen).
{ ... }:
{
  flake.modules.homeManager.fish = { pkgs, ... }: {
    programs.fish = {
      enable = true;

      # Aliases: literal command rewrites, invisible at the prompt.
      # Mirrors zsh.nix's shellAliases.
      shellAliases = {
        ll = "ls -lah";
        gs = "git status";
        gd = "git diff";
        gl = "git log --oneline --graph --decorate";
      };

      # Abbreviations: fish-native shortcuts that EXPAND inline when
      # you press space or enter. Discoverability win over plain
      # aliases — you see the real command before it runs and learn
      # it. Use abbreviations for things you want to learn the long
      # form of; use aliases (above) for things you actively don't
      # want to think about.
      shellAbbrs = {
        g = "git";
        ga = "git add";
        gc = "git commit";
        gco = "git checkout";
        gp = "git push";
        gpl = "git pull";
        gb = "git branch";
        gst = "git stash";
        # nix shortcuts
        nfu = "nix flake update";
        nfc = "nix flake check";
        nb = "nix build";
        nr-wip = "nix run nixpkgs#";
      };

      # Sane defaults + ported zsh customizations.
      interactiveShellInit = ''
        # Suppress the default "Welcome to fish, the friendly
        # interactive shell" banner on every new shell.
        set -U fish_greeting ""

        # Color tweaks: pair with starship's bold-green/bold-red
        # success/error symbol. Fish defaults are already reasonable;
        # nudge a couple to improve contrast in dark terminals.
        set -g fish_color_command            green   --bold
        set -g fish_color_param              normal
        set -g fish_color_redirection        cyan    --bold
        set -g fish_color_autosuggestion     brblack
        set -g fish_color_search_match       --background=brblack
        set -g fish_color_selection          --background=brblack
        set -g fish_color_error              red     --bold
        set -g fish_color_valid_path         --underline

        # History: fish stores history per-session in
        # ~/.local/share/fish/fish_history (line-based, one entry per
        # command, deduped on read by default). Match zsh.nix's
        # generous limit. fish_history_max is read at shell startup.
        set -U fish_history_max 100000

        # ── _flake_host: pick the host portion of a flake target ────
        # Same logic as zsh.nix's _flake_host. On bare-metal NixOS,
        # `hostname` matches a real `nixosConfigurations.<name>`. On
        # WSL2, `hostname` is the random Windows machine name and is
        # useless to us; we override based on /proc/sys/kernel/osrelease
        # (the canonical WSL detection signal — survives sudo/systemd
        # better than $WSL_DISTRO_NAME) and pick wsl/wsl-arm by arch.
        function _flake_host
            if test -r /proc/sys/kernel/osrelease
                and grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease
                switch (uname -m)
                    case aarch64
                        echo wsl-arm
                    case '*'
                        echo wsl
                end
            else
                hostname
            end
        end

        # Rebuild the system AND the user environment for the current
        # host. Mirrors zsh.nix's nr() — switches NixOS first, then
        # home-manager (so any HM unit referencing system paths sees
        # the new system already activated).
        function nr
            set -l host (_flake_host)
            sudo nixos-rebuild switch --flake ~/nixos#"$host"
            nix run home-manager/master -- switch --flake ~/nixos#"$USER@$host"
        end

        # Rebuild the user environment only. Mirrors zsh.nix's hm().
        function hm
            set -l host (_flake_host)
            nix run home-manager/master -- switch --flake ~/nixos#"$USER@$host"
        end
      '';

      # Sensible $fish_user_paths additions. fish_user_paths is a
      # universal variable, so ANY append at shell startup persists
      # across all sessions forever — guard with `contains` to keep
      # the list idempotent and avoid runaway duplicates.
      shellInit = ''
        for p in $HOME/.local/bin $HOME/bin
            if test -d $p
                if not contains $p $fish_user_paths
                    set -U fish_user_paths $p $fish_user_paths
                end
            end
        end
      '';
    };

    # ── Companion tool integrations ────────────────────────────────
    # Same set as zsh.nix wires for zsh, but with the fish-side flag.
    # Setting `enable = true` here is idempotent with zsh.nix — module
    # merging accepts the same value from both modules. The
    # `enable<Shell>Integration` flags are independent: a host can run
    # both shells and both will get the integrations.

    programs.dircolors = {
      enable = true;
      enableFishIntegration = true;
    };

    programs.starship = {
      enable = true;
      enableFishIntegration = true;
    };

    programs.fzf = {
      enable = true;
      enableFishIntegration = true;
    };

    programs.zoxide = {
      enable = true;
      enableFishIntegration = true;
    };

    programs.eza = {
      enable = true;
      enableFishIntegration = true;
    };

    programs.direnv = {
      enable = true;
      enableFishIntegration = true;
    };

    # CLI utilities the prompt + interactive workflow expect.
    # zsh.nix already installs these; declared again here so a
    # fish-only host (one that doesn't import zsh.nix) still gets them.
    home.packages = with pkgs; [
      ripgrep
      fd
      bat
      jq
      htop
    ];
  };
}
