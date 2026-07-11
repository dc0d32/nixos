# GitHub CLI (`gh`). Run `gh auth login` once on a machine, then
# subsequent git push/pull to github.com authenticates through the
# logged-in gh session via the credential helper installed below.
#
# Retire when: GitHub is no longer the primary forge (e.g. moved to
#   GitLab/Forgejo/sourcehut), OR git auth is centrally managed by a
#   different credential helper (e.g. system keyring, SSH-only).
{
  flake.modules.homeManager.gh = { lib, ... }: {
    programs.gh = {
      enable = true;

      # Installs the gh credential helper into git config so HTTPS
      # pushes/pulls authenticate through the logged-in gh session.
      gitCredentialHelper = {
        enable = true;
        hosts = [ "https://github.com" "https://gist.github.com" ];
      };
    };

    # home-manager writes ~/.config/gh/config.yml as a READ-ONLY Nix-store
    # symlink whenever programs.gh.enable = true — even with no `settings`
    # (contrary to a since-removed comment here). But `gh` rewrites config.yml
    # at runtime (e.g. it persists `git_protocol` during `gh auth login`),
    # which then fails with "open …/config.yml: read-only file system". Let gh
    # own config.yml as a normal writable file instead. Auth lives in the
    # separate, writable hosts.yml, and impermanence persists ~/.config/gh, so
    # nothing is lost. The credential helper above is set in git config, not
    # config.yml, so it is unaffected.
    xdg.configFile."gh/config.yml".enable = lib.mkForce false;
  };
}
