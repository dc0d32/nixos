# Git config — identity (name, email) and global ignores/aliases.
#
# Two ways to provide identity:
#
# 1. Literal values in the host bridge (legacy / no-secrets case):
#      git.name  = "Foo Bar";
#      git.email = "foo@example.com";
#    Written into ~/.gitconfig at HM activation; values land in the Nix store.
#    Suitable for hosts that don't / can't use sops-nix.
#
# 2. A sops-decrypted include file (preferred for the public flake):
#      git.identityFile = config.sops.secrets.git_identity.path;
#    The host bridge declares a sops secret whose decrypted contents are a
#    valid git config snippet:
#        [user]
#          name = Foo Bar
#          email = foo@example.com
#    `programs.git.includes` pulls it in at runtime; nothing identity-related
#    enters the Nix store. Requires the host to also import
#    config.flake.modules.homeManager.secrets and set secrets.commonFile.
#
# Mixing: if both are set, the include file wins (git applies includes after
# the main user.* block).
#
# Cross-class footprint: home-manager only (one user per host).
{ lib, config, ... }:
let
  cfg = config.git;
  haveIdentityFile = cfg.identityFile != null;
  haveLiteral = cfg.name != null && cfg.email != null;
in
{
  options.git = {
    name = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Commit author name written into ~/.gitconfig as a literal value.
        Set this OR git.identityFile (sops-decrypted include).
      '';
    };
    email = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Commit author email written into ~/.gitconfig as a literal value.
        Set this OR git.identityFile (sops-decrypted include).
      '';
    };
    identityFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "config.sops.secrets.git_identity.path";
      description = ''
        Path to a git-config snippet (typically a sops-decrypted file under
        /run/user/<uid>/secrets/) that declares [user] name + email.
        Included via programs.git.includes so the values never enter the
        Nix store.
      '';
    };
  };

  config.flake.modules.homeManager.git = {
    assertions = [
      {
        assertion = haveLiteral || haveIdentityFile;
        message = ''
          git module: either set both git.name + git.email to literal values,
          or set git.identityFile to the path of a sops-decrypted git-config
          snippet. Neither was supplied.
        '';
      }
    ];

    programs.git = {
      enable = true;
      settings = lib.mkMerge [
        # Always-on settings.
        {
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
        }
        # Literal identity, only if both name + email provided.
        (lib.mkIf haveLiteral {
          user = {
            name = cfg.name;
            email = cfg.email;
          };
        })
      ];
      ignores = [ ".DS_Store" "*.swp" ".direnv/" "result" "result-*" ];
      includes = lib.optionals haveIdentityFile [
        { path = cfg.identityFile; }
      ];
    };
  };
}
