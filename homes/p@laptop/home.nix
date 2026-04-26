{ variables, ... }: {
  # Host-specific overrides for this user go here.
  # The baseline modules (shell/editor/terminal/git/tmux/direnv + desktop on Linux)
  # are imported automatically via modules/home/default.nix.

  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
  };
}
