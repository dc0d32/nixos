# tmux — terminal multiplexer config (vi keys, mouse on, sane history,
# 256-color/truecolor passthrough, Mod+|/Mod+- splits, PageUp scrollback).
#
# No host-supplied data; identical config across hosts that want tmux.
#
# Retire when: tmux is dropped from the daily workflow, or replaced by
#   a different multiplexer (e.g. zellij, screen) on every host that
#   imports it.
{
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
        bind | split-window -h
        bind - split-window -v

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
