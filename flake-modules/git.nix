# Git config — identity (name, email) and global ignores/aliases.
#
# Top-level options:
#   - `git.name`  : commit author name
#   - `git.email` : commit author email
# Host modules set these; this feature module wires them into the
# user's home-manager config under `programs.git`.
#
# Cross-class footprint: home-manager only (one user per host).
#
# Migrated from modules/home/git.nix as part of the dendritic
# migration. See docs/sessions/2026-04-30-dendritic-migration.md.
{ lib, config, ... }:
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
          name = config.git.name;
          email = config.git.email;
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
