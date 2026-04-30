# zsh + companion shell tools (starship, fzf, zoxide, eza, dircolors,
# ripgrep/fd/bat/jq/htop) — interactive shell environment.
#
# Migrated from modules/home/shell/zsh.nix. Pure-leaf module; no host data.
#
# Retire when: the user no longer wants zsh as their interactive shell or
# wants the companion tools split out per-feature.
{
  flake.modules.homeManager.zsh = { pkgs, ... }: {
    programs.zsh = {
      enable = true;
      autocd = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      enableCompletion = true;
      history = {
        size = 100000;
        save = 100000;
        share = true;
        ignoreDups = true;
        ignoreAllDups = true;
        extended = true;
      };
      shellAliases = {
        ll = "ls -lah";
        gs = "git status";
        gd = "git diff";
        gl = "git log --oneline --graph --decorate";
      };
      initContent = ''
        bindkey -e

        # fzf-tab: must be sourced after compinit but before syntax-highlighting.
        # home-manager runs compinit and then sources initContent, so this is the
        # correct place. autosuggestions loads before initContent; that's fine —
        # fzf-tab only needs to precede syntax-highlighting (sourced after).
        source ${pkgs.zsh-fzf-tab}/share/fzf-tab/fzf-tab.plugin.zsh

        zstyle ':completion:*' auto-description 'specify: %d'
        zstyle ':completion:*' completer _expand _complete _correct _approximate
        zstyle ':completion:*' format 'Completing %d'
        zstyle ':completion:*' group-name ""
        zstyle ':completion:*' menu select=2
        zstyle ':completion:*:default' list-colors "''${(s.:.)LS_COLORS}"
        zstyle ':completion:*' list-colors ""
        zstyle ':completion:*' list-prompt '%SAt %p: Hit TAB for more, or the character to insert%s'
        zstyle ':completion:*' matcher-list "" 'm:{a-z}={A-Z}' 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=* l:|=*'
        zstyle ':completion:*' menu select=long
        zstyle ':completion:*' select-prompt '%SScrolling active: current selection at %p%s'
        zstyle ':completion:*' use-compctl false
        zstyle ':completion:*' verbose true
        zstyle ':completion:*:*:kill:*:processes' list-colors '=(#b) #([0-9]#)*=0=01;31'
        zstyle ':completion:*:kill:*' command 'ps -u $USER -o pid,%cpu,tty,cputime,cmd'

        nr() {
          local host="$(hostname)"
          sudo nixos-rebuild switch --flake ~/nixos#"$host"
          nix run home-manager/master -- switch --flake ~/nixos#"$USER@$host"
        }

        hm() {
          local host="$(hostname)"
          nix run home-manager/master -- switch --flake ~/nixos#"$USER@$host"
        }
      '';
    };

    # dircolors populates LS_COLORS and integrates with zsh so the zstyle
    # ':completion:*:default' list-colors picks it up automatically.
    programs.dircolors = {
      enable = true;
      enableZshIntegration = true;
    };

    programs.starship = {
      enable = true;
      enableZshIntegration = true;
      settings = {
        add_newline = false;
        format = "$directory$git_branch$git_status$nix_shell$character";
        directory = {
          truncation_length = 3;
        };
        character = {
          success_symbol = "[>](bold green)";
          error_symbol = "[>](bold red)";
        };
      };
    };

    programs.fzf = {
      enable = true;
      enableZshIntegration = true;
    };

    programs.zoxide = {
      enable = true;
      enableZshIntegration = true;
    };

    programs.eza = {
      enable = true;
      enableZshIntegration = true;
    };

    home.packages = with pkgs; [
      ripgrep
      fd
      bat
      jq
      htop
    ];
  };
}
