{ pkgs, ... }:
{
  # Extra system packages specific to this host.
  # Most packages should live in home-manager; reserve this for
  # things that must exist at the system level.
  environment.systemPackages = with pkgs; [
    git
    vim
    curl
    wget
  ];
}
