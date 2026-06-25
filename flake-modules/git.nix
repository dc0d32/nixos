# Git config — identity (name, email), global ignores/aliases, and the
# git tooling layer: delta (diff pager), lazygit (TUI), git-lfs.
#
# Identity defaults to the "CHANGEME" placeholder (a public flake whose
# real author identity is already on the commit log). Hosts that want a
# different identity override `git.name` / `git.email` in their bridge.
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
      default = "CHANGEME";
      description = "Commit author name written into ~/.gitconfig.";
    };
    email = lib.mkOption {
      type = lib.types.str;
      default = "CHANGEME@example.com";
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
          # On-demand structural (AST) diff via difftastic, leaving
          # delta as the default pager for plain `git diff`. difftastic
          # is installed in flake-modules/zsh.nix.
          dft = "-c diff.external=difft diff";
        };
      };
      ignores = [ ".DS_Store" "*.swp" ".direnv/" "result" "result-*" ];

      # git-lfs: installs the binary AND registers the smudge/clean/
      # process filters in git config, so `git lfs track`d artifacts
      # (models, datasets) work without a manual per-repo `git lfs
      # install`.
      lfs.enable = true;
    };

    # delta — syntax-highlighted diff pager. enableGitIntegration wires
    # it as core.pager / interactive.diffFilter; must be set explicitly
    # (HM deprecated the implicit default).
    programs.delta = {
      enable = true;
      enableGitIntegration = true;
      options = {
        navigate = true; # n / N to jump between diff hunks
        line-numbers = true;
        side-by-side = true;
      };
    };

    # lazygit — terminal UI for git (aliased `lg` in zsh). Pipe its
    # diffs through delta to match `git diff` output.
    programs.lazygit = {
      enable = true;
      # lazygit 0.61 replaced the single `git.paging` object with a
      # `git.pagers` array. Use the new schema directly: home-manager
      # writes this config as a read-only /nix/store symlink, so if the
      # on-disk schema were stale lazygit would try to migrate it in
      # place on launch and fail with "read-only file system".
      settings.git.pagers = [
        { pager = "delta --dark --paging=never"; }
      ];
    };
  };
}
