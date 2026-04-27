{ ... }: {
  programs.alacritty = {
    enable = true;
    settings = {
      window = {
        padding = { x = 8; y = 8; };
        decorations = "none";
      };
      font = {
        normal.family = "RecMonoCasual Nerd Font";
        size = 10;
      };
      cursor.style.shape = "Beam";
      scrolling.history = 100000;
    };
  };
}
