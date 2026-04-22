{ pkgs, ... }: {
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
    '';
  };
}
