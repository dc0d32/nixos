# alacritty — GPU-accelerated terminal.
#
# Pattern A: hosts opt in by importing this module.
#
# Also publishes `flake.lib.alacrittySettings` so the native-Windows
# generator (flake-modules/windows/windows.nix, `hm_win`) emits an
# alacritty.toml from the same definition.
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

  # Alacritty settings shared with the native-Windows generator in
  # flake-modules/windows/windows.nix (`hm_win`), so the terminal looks
  # and behaves the same on Linux and on Windows from one definition. The
  # Windows side overrides `window.decorations` (Linux runs borderless
  # under niri; Windows has no WM to move/close a borderless window).
  settings = {
    window = {
      padding = { x = 8; y = 8; };
      decorations = "none";
    };
    font = {
      # Use the "… Nerd Font Mono" family, NOT the bare
      # "FantasqueSansM Nerd Font". The non-Mono patched family keeps
      # the Nerd glyphs at their original (often 1.5–2×) advance
      # width, which doesn't match alacritty's fixed terminal cell —
      # the result is overlapping letters and gaps. The Mono variant
      # forces every glyph (icons included) into a single cell, so
      # the grid stays aligned.
      #
      # Pin the style explicitly too: some Nerd-Font RIBBI families
      # (notably Adwaita Mono) confuse alacritty's face matcher into
      # picking Italic when only the family is given. Naming the
      # style forces the upright face.
      normal = {
        family = "FantasqueSansM Nerd Font Mono";
        style = "Regular";
      };
      size = 12;
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
in
{
  # Published so the native-Windows generator (hm_win) can emit an
  # alacritty.toml from the exact same definition.
  flake.lib.alacrittySettings = settings;

  flake.modules.homeManager.alacritty = {
    programs.alacritty = {
      enable = true;
      inherit settings;
    };
  };
}
