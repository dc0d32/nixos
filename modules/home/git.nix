{ variables, ... }: {
  programs.git = {
    enable = true;
    userName = variables.git.name or variables.user or "change me";
    userEmail = variables.git.email or "change@me.invalid";
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      rebase.autoStash = true;
      merge.conflictStyle = "zdiff3";
      diff.algorithm = "histogram";
      color.ui = "auto";
    };
    aliases = {
      st = "status -sb";
      co = "checkout";
      ci = "commit";
      br = "branch";
      lg = "log --oneline --graph --decorate --all";
    };
    ignores = [ ".DS_Store" "*.swp" ".direnv/" "result" "result-*" ];
  };
}
