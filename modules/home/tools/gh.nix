{ pkgs, ... }:
# GitHub CLI. Run `gh auth login` once on a machine, then `gh auth setup-git`
# (which this module does declaratively) so git push/pull to github.com just
# works without further credential dancing.
{
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
  };

  # Installs the gh credential helper into git config so HTTPS pushes/pulls
  # authenticate through the logged-in gh session.
  programs.gh.gitCredentialHelper = {
    enable = true;
    hosts = [ "https://github.com" "https://gist.github.com" ];
  };
}
