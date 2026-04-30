# GitHub CLI (`gh`). Run `gh auth login` once on a machine, then
# subsequent git push/pull to github.com authenticates through the
# logged-in gh session via the credential helper installed below.
#
# Migrated from modules/home/tools/gh.nix.
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
