# alacritty — GPU-accelerated terminal.
#
# Pattern A: hosts opt in by importing this module.
#
# Retire when: alacritty is dropped in favor of a different terminal
#   (e.g. ghostty, foot, kitty), or when no host in the repo wants a
#   GUI terminal at all.
{ ... }:
let
  # ESC[5~ / ESC[6~ — the byte sequences a terminal sends for PageUp /
  # PageDown. Built via JSON because Nix string literals have no \e/\x
  # escape for the ESC control character.
  pageUpKey = builtins.fromJSON ''"\u001b[5~"'';
  pageDownKey = builtins.fromJSON ''"\u001b[6~"'';
in
{
  flake.modules.homeManager.alacritty = {
    programs.alacritty = {
      enable = true;
      settings = {
        window = {
          padding = { x = 8; y = 8; };
          decorations = "none";
        };
        font = {
          normal.family = "AdwaitaMono Nerd Font";
          size = 10;
        };
        cursor.style.shape = "Beam";
        scrolling.history = 100000;

        # Plain PageUp/PageDown scroll the scrollback at the shell prompt
        # (the "primary" screen, matched by `~Alt`). Inside full-screen
        # apps that use the alternate screen — less, vim, htop, fzf,
        # tmux — the keys are passed through (`Alt` mode) so those apps
        # keep their own paging. Shift+PageUp/Down still scroll too
        # (alacritty's built-in default).
        keyboard.bindings = [
          { key = "PageUp"; mode = "~Alt"; action = "ScrollPageUp"; }
          { key = "PageDown"; mode = "~Alt"; action = "ScrollPageDown"; }
          { key = "PageUp"; mode = "Alt"; chars = pageUpKey; }
          { key = "PageDown"; mode = "Alt"; chars = pageDownKey; }
        ];
      };
    };
  };
}
