# Git config — identity (name, email) and global ignores/aliases.
#
# Identity is set by literal values in the host bridge:
#   git.name  = "Foo Bar";
#   git.email = "foo@example.com";
# Both are written into ~/.gitconfig at HM activation; values land in the
# Nix store. This is fine for a public flake whose author identity is
# already on the commit log, less fine for shared author values you'd
# rather not publish — that case is what a future secrets framework would
# address (see AGENTS.md: not yet wired).
#
# Cross-class footprint: home-manager only (one user per host).
#
# Retire when: git is no longer the SCM in use (e.g. jj/sapling takes
#   over), OR identity propagation moves into a dedicated identity
#   module shared across services beyond just git.
{ lib, config, ... }:
let
  cfg = config.git;
in
{
  options.git = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "Commit author name written into ~/.gitconfig.";
    };
    email = lib.mkOption {
      type = lib.types.str;
      description = "Commit author email written into ~/.gitconfig.";
    };
  };

  config.flake.modules.homeManager.git = {
    programs.git = {
      enable = true;
      settings = {
        user = {
          name = cfg.name;
          email = cfg.email;
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
  };
}
