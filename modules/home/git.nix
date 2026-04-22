{ variables, ... }: {
  programs.git = {
    enable = true;
    settings = {
      user = {
        name  = variables.git.name  or variables.user or "change me";
        email = variables.git.email or "change@me.invalid";
      };
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      rebase.autoStash = true;
      merge.conflictStyle = "zdiff3";
      diff.algorithm = "histogram";
      color.ui = "auto";
      alias = {
        st = "status -sb";
        co = "checkout";
        ci = "commit";
        br = "branch";
        lg = "log --oneline --graph --decorate --all";
      };
    };
    ignores = [ ".DS_Store" "*.swp" ".direnv/" "result" "result-*" ];
  };
}
