# zsh + companion shell tools (starship, fzf, zoxide, eza, atuin,
# dircolors, ripgrep/fd/bat/jq/htop, plus a data-science / ML CLI
# toolkit: duckdb, visidata, miller, qsv, gron, jless, dasel, lnav,
# difftastic, glow, tealdeer, uv, numbat) — interactive shell
# environment.
#
# Git tooling (delta as the diff pager, lazygit TUI, git-lfs) is wired
# in flake-modules/git.nix, not here.
#
# These are dropped here (the existing "terminal tools" home) as a
# pragmatic stop-gap; a future refactor will split them into a dedicated
# `terminal-tools` workload bundle (see the refactor-workload-bundles
# follow-up).
#
# Retire when: the user no longer wants zsh as their interactive shell or
# wants the companion tools split out per-feature.
{ config, ... }:
{
  flake.modules.homeManager.zsh = { pkgs, ... }:
    let
      # The terminal guide shown by `tools`. Kept as an external Markdown
      # file (terminal-help.md) rather than inline — it spans the whole
      # environment's commands and would be unwieldy in this module.
      helpDoc = ./terminal-help.md;
    in
    {
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
          lg = "lazygit";
        };
        initContent = ''
          bindkey -e

          # Home / End / Delete — make the navigation keys work across
          # terminals (alacritty, Windows Terminal, the VS Code terminal,
          # and inside tmux). `bindkey -e` only gives the emacs chords
          # (^A/^E); the physical Home/End keys send terminal-specific
          # escape sequences that zsh doesn't bind by default. Cover the
          # CSI (~app-cursor), SS3 (app-cursor) and vt-style `~` forms.
          bindkey '^[[H'  beginning-of-line   # Home (CSI)
          bindkey '^[OH'  beginning-of-line   # Home (SS3 / app-cursor)
          bindkey '^[[1~' beginning-of-line   # Home (vt)
          bindkey '^[[F'  end-of-line         # End  (CSI)
          bindkey '^[OF'  end-of-line         # End  (SS3 / app-cursor)
          bindkey '^[[4~' end-of-line         # End  (vt)
          bindkey '^[[3~' delete-char         # Delete (forward)

          # Ctrl+Left / Ctrl+Right — move by word. Cover the xterm
          # modifyOtherKeys CSI form (alacritty, Windows Terminal, the
          # VS Code terminal, tmux) and the older modifier form.
          bindkey '^[[1;5D' backward-word     # Ctrl+Left
          bindkey '^[[1;5C' forward-word      # Ctrl+Right
          bindkey '^[[5D'   backward-word     # Ctrl+Left (legacy)
          bindkey '^[[5C'   forward-word      # Ctrl+Right (legacy)

          # PageUp / PageDown — swallow them in the line editor so the
          # terminal (or tmux) handles scrollback and zsh doesn't
          # self-insert the stray `~` from the unbound ^[[5~ / ^[[6~
          # escape sequences. `zle -N` a do-nothing widget and bind both.
          _pager_noop() { }
          zle -N _pager_noop
          bindkey '^[[5~' _pager_noop         # PageUp
          bindkey '^[[6~' _pager_noop         # PageDown

          # One-time: seed atuin from this shell's existing history (atuin
          # starts empty and does not auto-absorb past history). The
          # marker lives in atuin's data dir, which is persisted across
          # the impermanence root-wipe, so this runs exactly once ever.
          if command -v atuin >/dev/null 2>&1; then
            _atuin_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/atuin"
            if [[ ! -f "$_atuin_dir/.imported" ]]; then
              atuin import auto >/dev/null 2>&1 || true
              mkdir -p "$_atuin_dir" && touch "$_atuin_dir/.imported"
            fi
            unset _atuin_dir
          fi

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

          # _flake_host: pick the host portion of a flake target.
          #
          # On bare-metal NixOS, `hostname` matches a real
          # `nixosConfigurations.<name>` entry, so we just use it.
          #
          # On WSL, `hostname` is the random Windows machine name and
          # has nothing to do with our flake. All WSL instances share
          # one of two configs split only by CPU arch
          # (see flake-modules/hosts/wsl.nix):
          #   x86_64-linux  → `wsl`
          #   aarch64-linux → `wsl-arm`
          # so we override the hostname when /proc/sys/kernel/osrelease
          # advertises WSL (this string is set by the WSL2 kernel and
          # is the canonical detection signal — `$WSL_DISTRO_NAME`
          # works too but isn't always inherited by sudo / systemd).
          _flake_host() {
            if [[ -r /proc/sys/kernel/osrelease ]] && \
               grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease; then
              case "$(uname -m)" in
                aarch64) echo wsl-arm ;;
                *)       echo wsl ;;
              esac
            else
              hostname
            fi
          }

          nr() {
            local host="$(_flake_host)"
            sudo nixos-rebuild switch --flake ~/nixos#"$host"
            nix run home-manager/master -- switch --flake ~/nixos#"$USER@$host"
          }

          hm() {
            local host="$(_flake_host)"
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
        # Shared with the native-Windows PowerShell prompt: the single
        # definition lives in flake-modules/windows/windows.nix and is
        # rendered to ~/.config/starship.toml there too (see hm_win).
        settings = config.flake.lib.starshipSettings;
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

      # Searchable, SQLite-backed shell history (Ctrl-R + up-arrow). The
      # store at ~/.local/share/atuin is already carved out in
      # flake-modules/impermanence.nix, so history survives the root wipe.
      programs.atuin = {
        enable = true;
        enableZshIntegration = true;
      };

      home.packages = with pkgs; [
        ripgrep
        fd
        bat
        jq
        htop

        # ── Data-science / ML CLI toolkit ───────────────────────────
        # Tabular data wrangling
        duckdb # in-process SQL over CSV/TSV/JSON/Parquet
        visidata # interactive TUI for tabular data (vd)
        miller # awk/cut/join/stats for CSV/TSV/JSON (mlr)
        qsv # fast CSV toolkit (stats/dedup/join/sample)
        # JSON / structured data
        gron # flatten JSON into greppable lines
        jless # interactive JSON pager/viewer
        dasel # query+convert JSON/YAML/TOML/CSV/XML
        # Logs
        lnav # log-file navigator with SQL over lines
        # Git / diff — delta (pager), lazygit (TUI) and git-lfs are wired
        # in flake-modules/git.nix. difftastic stays a standalone `difft`
        # here: home-manager asserts only one differ may own git
        # integration, and that slot is delta's.
        difftastic # structural (AST) diff (difft)
        # Python / ML
        uv # fast Python package + venv manager
        # Docs / help
        glow # render markdown in the terminal
        tealdeer # fast tldr cheatsheets (tldr)
        # Misc
        numbat # unit-aware scientific calculator

        # Verbose, kid-followable terminal guide — run `tools`. Renders the
        # `helpDoc` Markdown (defined in the `let` above) through glow on a
        # terminal, falling back to plain text when piped/redirected. A
        # future terminal-tools bundle refactor can carry this along.
        # (Named `tools`, not `help`: `help` is a builtin in PowerShell on
        # the Windows side, so the command name is kept identical across
        # both platforms.)
        (writeShellApplication {
          name = "tools";
          runtimeInputs = [ coreutils glow ];
          text = ''
            if [ -t 1 ]; then
              glow "${helpDoc}"
            else
              cat "${helpDoc}"
            fi
          '';
        })
      ];
    };
}
