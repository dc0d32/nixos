# GitHub CLI (`gh`). Run `gh auth login` once on a machine, then
# subsequent git push/pull to github.com authenticates through the
# logged-in gh session via the credential helper installed below.
#
# Retire when: GitHub is no longer the primary forge (e.g. moved to
#   GitLab/Forgejo/sourcehut), OR git auth is centrally managed by a
#   different credential helper (e.g. system keyring, SSH-only).
{
  flake.modules.homeManager.gh = {
    programs.gh = {
      enable = true;
      settings = {
        git_protocol = "https";
        prompt = "enabled";
        editor = "nvim";
        aliases = {
          co = "pr checkout";
          pv = "pr view";
        };
      };

      # Installs the gh credential helper into git config so HTTPS
      # pushes/pulls authenticate through the logged-in gh session.
      gitCredentialHelper = {
        enable = true;
        hosts = [ "https://github.com" "https://gist.github.com" ];
      };
    };
  };
}
