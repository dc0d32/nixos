# zsh + companion shell tools (starship, fzf, zoxide, eza, atuin,
# dircolors, ripgrep/fd/bat/jq/htop, plus a data-science / ML CLI
# toolkit: duckdb, visidata, miller, gron, jless, dasel, lnav,
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
  flake.modules.homeManager.zsh = { pkgs, lib, inputs, ... }:
    let
      # The terminal guide shown by `tools`. Kept as an external Markdown
      # file (terminal-help.md) rather than inline — it spans the whole
      # environment's commands and would be unwieldy in this module.
      helpDoc = ./terminal-help.md;
    in
    {
      # nix-index-database ships a weekly-updated prebuilt nix-index DB and
      # wraps nix-index/nix-locate against it, so comma + command-not-found
      # work immediately with no local `nix-index` build. Must NOT also add
      # `nix-index` or `comma` to home.packages (the module owns both).
      imports = [ inputs.nix-index-database.homeModules.default ];

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
        initContent = lib.optionalString pkgs.stdenv.isDarwin ''
          # macOS updates overwrite /etc/zshrc, nuking the Nix daemon
          # hook the installer placed there. Source it from ~/.zshrc so
          # nix stays on PATH regardless. Idempotent — harmless if
          # /etc/zshrc also sources it.
          if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
            . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
          fi
        '' + ''
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
          # On macOS, `hostname` returns the FQDN (e.g. `pb-mb.lan`),
          # which won't match the flake config name `pb-mb` — strip the
          # domain (everything after the first dot). Harmless on Linux,
          # where the name is already short.
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
              local h="$(hostname)"
              echo "''${h%%.*}"   # strip any DNS domain (e.g. pb-mb.lan → pb-mb)
            fi
          }

          nr() {
            local host="$(_flake_host)"
            sudo nixos-rebuild switch --flake "$NH_FLAKE#$host"
            nix run home-manager/master -- switch --flake "$NH_FLAKE#$USER@$host"
          }

          hm() {
            local host="$(_flake_host)"
            nix run home-manager/master -- switch --flake "$NH_FLAKE#$USER@$host"
          }

          # nh (nix-helper) flake target — set here too (not just
          # home.sessionVariables) so running shells get it without a
          # re-login. `nh os switch` / `nh home switch` then need no path.
          export NH_FLAKE="''${NH_FLAKE:-$HOME/nixos}"

          # nh wrapper: make `nh os|home switch` target the SAME flake host
          # as nr/hm. Plain nh derives the configuration name from the
          # system hostname, which on WSL is the (irrelevant) Windows
          # machine name — so inject the _flake_host value explicitly via
          # `-H <host>` (os) / `-c <user@host>` (home). On bare metal those
          # match nh's own auto-detection, so this is a no-op there and the
          # fix on WSL. Also maps the Windows dotfiles deploy (hm_win) onto
          # nh, available only where the windows module is imported (WSL):
          #   nh win switch  → hm_win --setup  (full apply: dotfiles +
          #                    winget/Scoop/uv installs, parity with
          #                    `nh os switch`)
          #   nh win deploy  → hm_win          (fast: just redeploy the
          #                    Nix-generated dotfiles)
          # Anything else (search, clean, os boot, …) passes through.
          nh() {
            local host action
            case "$1" in
              win)
                shift
                if ! command -v hm_win >/dev/null 2>&1; then
                  echo "nh win: hm_win is not available on this host (WSL only)." >&2
                  return 1
                fi
                case "$1" in
                  switch) shift; hm_win --setup "$@" ;;
                  deploy) shift; hm_win "$@" ;;
                  *) hm_win "$@" ;;
                esac
                ;;
              os)
                shift
                host="$(_flake_host)"
                case "$1" in
                  switch | boot | test | build)
                    if [[ " $* " == *" -H "* || " $* " == *" --hostname "* ]]; then
                      command nh os "$@"
                    else
                      action="$1"; shift
                      command nh os "$action" --hostname "$host" "$@"
                    fi
                    ;;
                  *) command nh os "$@" ;;
                esac
                ;;
              home)
                shift
                host="$(_flake_host)"
                case "$1" in
                  switch | build)
                    if [[ " $* " == *" -c "* || " $* " == *" --configuration "* ]]; then
                      command nh home "$@"
                    else
                      action="$1"; shift
                      command nh home "$action" --configuration "$USER@$host" "$@"
                    fi
                    ;;
                  *) command nh home "$@" ;;
                esac
                ;;
              *)
                command nh "$@"
                ;;
            esac
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
        # Live preview: directories tree via eza, files via bat. Speeds
        # up Ctrl-T / **<tab> picks and zoxide jumps. (eza/bat are in
        # home.packages below; programs.eza is enabled in this module.)
        defaultCommand = "fd --hidden";
        changeDirWidgetCommand = "fd --type d";
        fileWidgetCommand = "fd --type f";
        defaultOptions = [
          "--preview 'if [ -d {} ]; then eza --tree --level=1 --color=always --icons=always {}; else bat --color=always {}; fi'"
        ];
      };

      programs.zoxide = {
        enable = true;
        enableZshIntegration = true;
        # `cd` becomes zoxide; first arg-free `cd` still works, and
        # frecency jumps via `cd <partial>`.
        options = [ "--cmd cd" ];
      };

      # comma — run any program from nixpkgs without installing it
      # (`, cowsay hi`). The nix-index-database HM module installs a comma
      # wrapped against its prebuilt DB; programs.nix-index keeps nix-locate
      # warm for command-not-found too. No `nix-index` build needed locally.
      programs.nix-index = {
        enable = true;
        enableZshIntegration = true;
      };
      programs.nix-index-database.comma.enable = true;

      programs.eza = {
        enable = true;
        enableZshIntegration = true;
      };

      # Searchable, SQLite-backed shell history. Bound to Ctrl-R only —
      # `--disable-up-arrow` keeps the Up key as plain zsh history
      # navigation (recall the previous command on the line and edit it),
      # instead of atuin hijacking Up to open its full-screen search UI.
      # The store at ~/.local/share/atuin is already carved out in
      # flake-modules/impermanence.nix, so history survives the root wipe.
      #
      # Speed: the daemon moves atuin's per-command history write off the
      # interactive hot path — without it the zsh preexec/precmd hooks do a
      # synchronous SQLite write on every command, adding prompt latency
      # (the "atuin feels slow" symptom). It's socket-activated via a
      # systemd user unit on Linux (launchd on Darwin), so it costs nothing
      # until first use. `style = "compact"` + a small `inline_height` draw
      # Ctrl-R inline instead of repainting a full-screen TUI, so the
      # picker pops instantly. `forceOverwriteSettings` lets HM own
      # config.toml even though atuin rewrites its own default after every
      # command (otherwise activation trips over the file atuin left).
      programs.atuin = {
        enable = true;
        enableZshIntegration = true;
        flags = [ "--disable-up-arrow" ];
        daemon.enable = true;
        forceOverwriteSettings = true;
        # Shared cross-platform style (also used by the Windows profile via
        # hm_win). The daemon.* keys are layered on by daemon.enable above.
        settings = config.flake.lib.atuinSettings;
      };

      home.packages = with pkgs; [
        ripgrep
        fd
        bat
        jq
        htop

        nh # friendly nixos-rebuild / home-manager wrapper (`nh os switch`)

        # nix-search-tv + fzf: `ns` fuzzy-search nixpkgs with live preview
        (writeShellApplication {
          name = "ns";
          runtimeInputs = [ fzf nix-search-tv ];
          text = builtins.readFile "${nix-search-tv.src}/nixpkgs.sh";
        })

        # ── Terminal file managers ──────────────────────────────────
        yazi # blazing-fast Rust TUI file manager (yazi)
        vifm # vi-keybinding dual-pane file manager (vifm)

        # ── Data-science / ML CLI toolkit ───────────────────────────
        # Tabular data wrangling
        duckdb # in-process SQL over CSV/TSV/JSON/Parquet
        visidata # interactive TUI for tabular data (vd)
        miller # awk/cut/join/stats for CSV/TSV/JSON (mlr)
        # JSON / structured data
        gron # flatten JSON into greppable lines
        jless # interactive JSON pager/viewer
        jaq # faster jq drop-in (correctness + speed focused)
        dasel # query+convert JSON/YAML/TOML/CSV/XML
        # HTTP
        xh # friendly, fast HTTP client (HTTPie-style)
        # Archives
        ouch # one tool to (de)compress tar/zip/gz/zst/7z/…
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
        # `md-view <file>` — glow with this repo's settings pinned:
        # our own heading style (no leftover `##`), a width that suits
        # the docs, and a pager with mouse scrolling. Also normalises
        # the input to a `.md` path first, because glow renders Markdown
        # only for files NAMED `.md` and otherwise prints the source —
        # so `md-view README`, `md-view notes.markdown` and
        # `curl -s … | md-view` all work where bare `glow` would not.
        # `tools` and `guide` are thin wrappers over this.
        (config.flake.lib.mkMarkdownViewer pkgs)
        tealdeer # fast tldr cheatsheets (tldr)
        navi # interactive cheatsheet launcher (navi)
        # Misc
        numbat # unit-aware scientific calculator

        # Verbose, kid-followable terminal guide — run `tools`. Renders the
        # `helpDoc` Markdown (defined in the `let` above) through the shared
        # viewer, falling back to plain text when piped/redirected. A
        # future terminal-tools bundle refactor can carry this along.
        # (Named `tools`, not `help`: `help` is a builtin in PowerShell on
        # the Windows side, so the command name is kept identical across
        # both platforms.)
        #
        # Rendering goes through `flake.lib.mkMarkdownViewer`
        # (flake-modules/markdown-viewer.nix) rather than a bare `glow`
        # call. `tools` was NOT broken — terminal-help.md is a real .md
        # file, which is exactly what `guide` was missing — but it was
        # inheriting the terminal's style guess and glow's 80-column
        # fallback, which mangles the wider tables. Sharing one pinned
        # invocation with `guide` means the two pages look the same and
        # can't drift. See that module's header.
        (writeShellApplication {
          name = "tools";
          runtimeInputs = [ coreutils ];
          text = ''
            exec ${lib.getExe (config.flake.lib.mkMarkdownViewer pkgs)} "${helpDoc}"
          '';
        })
      ];

      # DuckDB CLI init file. `duckdb -ui` (and any function that lives in
      # an official extension) needs the `ui` extension auto-fetched on
      # demand; DuckDB ships with autoinstall/autoload OFF, so a bare
      # `duckdb -ui` errors with "start_ui is not in the catalog". Turning
      # both on for known (signed, official) extensions makes the UI — and
      # httpfs/json/etc. — just work. Read from ~/.duckdbrc on every launch.
      home.file.".duckdbrc".text = ''
        SET autoinstall_known_extensions = 1;
        SET autoload_known_extensions = 1;
      '';

      # nh (nix-helper, installed via dev-shell) reads NH_FLAKE so
      # `nh os switch` / `nh home switch` don't need a flake path arg.
      home.sessionVariables.NH_FLAKE = lib.mkDefault "$HOME/nixos";
    };
}
