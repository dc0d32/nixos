# tmux — terminal multiplexer config (vi keys, mouse on, sane history,
# 256-color/truecolor passthrough, Mod+|/Mod+- splits, PageUp scrollback,
# and a tasteful minimal status bar).
#
# The portable subset (QOL binds + status bar — everything that also works
# on native Windows) is published as `flake.lib.tmuxPortableConfig` and
# consumed by flake-modules/windows for psmux, so the two configs can't
# drift. Linux-only lines (terminfo truecolor, the alternate-screen PageUp
# passthrough) and the per-platform reload path stay in their own module.
#
# No host-supplied data; identical config across hosts that want tmux.
#
# Retire when: tmux is dropped from the daily workflow, or replaced by
#   a different multiplexer (e.g. zellij, screen) on every host that
#   imports it.
let
  # Shared with psmux on Windows. Only plain settings/binds that psmux
  # implements natively — no format conditionals, no `send -X`, no
  # terminfo. Colours: colour39 accent (active pane / current window /
  # session), colour245 muted text, colour238 separators, colour232 near
  # black for the current-window label on the accent background.
  tmuxPortableConfig = ''
    # --- Quality-of-life binds (portable: tmux + psmux) ---
    set -g focus-events on
    set -g display-time 1500

    # New splits and windows inherit the current pane's working directory.
    bind | split-window -h -c "#{pane_current_path}"
    bind - split-window -v -c "#{pane_current_path}"
    bind c new-window -c "#{pane_current_path}"

    # Vim-style pane navigation (prefix then h/j/k/l).
    bind h select-pane -L
    bind j select-pane -D
    bind k select-pane -U
    bind l select-pane -R

    # Repeatable pane resize (prefix then H/J/K/L, repeat within repeat-time).
    bind -r H resize-pane -L 5
    bind -r J resize-pane -D 5
    bind -r K resize-pane -U 5
    bind -r L resize-pane -R 5

    # --- Status bar (informative, rounded, RDP-readable, not gaudy) ---
    # Nerd Font powerline caps round the two identity anchors: the session
    # pill (left) and the current-window pill. Exactly one bright pill =
    # "you are here", so it stays legible through remote-desktop colour
    # compression. Everything else is muted text on a defined dark bar
    # (colour235), which RDP renders more consistently than a transparent
    # one. Icons are core Font Awesome glyphs, present in every Nerd Font.
    set -g status-interval 5
    set -g status-justify left
    set -g status-style "bg=colour235,fg=colour250"
    # Left: session pill (muted teal — identity, not alarm).
    set -g status-left "#[fg=colour31,bg=colour235]#[fg=colour232,bg=colour31,bold] #S #[fg=colour31,bg=colour235]#[default] "
    set -g status-left-length 40
    # Windows: the current one is the only bright rounded pill.
    setw -g window-status-separator " "
    setw -g window-status-format "#[fg=colour245,bg=colour235] #I:#W "
    setw -g window-status-current-format "#[fg=colour39,bg=colour235]#[fg=colour232,bg=colour39,bold] #I:#W #[fg=colour39,bg=colour235]#[default]"
    # Right: dir slug · machine · short date + time (minute in accent).
    set -g status-right "#[fg=colour245] #{b:pane_current_path}  #[fg=colour109,bold] #H  #[fg=colour250] %a %d %b #[fg=colour39,bold]%H:%M "
    set -g status-right-length 70
    set -g pane-border-style "fg=colour238"
    set -g pane-active-border-style "fg=colour39"
  '';
in
{
  flake.lib.tmuxPortableConfig = tmuxPortableConfig;

  flake.modules.homeManager.tmux = {
    programs.tmux = {
      enable = true;
      terminal = "tmux-256color";
      baseIndex = 1;
      keyMode = "vi";
      mouse = true;
      escapeTime = 10;
      historyLimit = 100000;
      extraConfig = ''
        set -g renumber-windows on
        set -ga terminal-overrides ",*256col*:Tc"

        ${tmuxPortableConfig}
        # Reload this config in place (prefix r).
        bind r source-file ~/.config/tmux/tmux.conf \; display "config reloaded"

        # PageUp enters copy-mode and scrolls back one page (vi copy-mode
        # then handles further PageUp/PageDown). Inside a full-screen app
        # on the alternate screen (less, vim, htop) the key is passed
        # through so the app pages instead. `copy-mode -eu` = enter
        # copy-mode, page up, and auto-exit when scrolled back to bottom.
        bind -n PageUp if-shell -F "#{alternate_on}" "send-keys PageUp" "copy-mode -eu"
      '';
    };
  };
}
