#!/usr/bin/env bash
# Install explicit administrator trust for the standalone Mac cache client.
# Retire when the Mac no longer uses this cache or its installer manages trust.
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "This setup is for macOS only." >&2
  exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."
command -v home-manager >/dev/null || {
  echo "home-manager must be installed before running this setup." >&2
  exit 1
}

hm_out="$(nix build --no-link --print-out-paths \
  .#homeConfigurations.'p@pb-mb'.activationPackage)"
fragment="$hm_out/home-files/.config/nix/lan-cache-daemon.conf"
if [[ ! -f "$fragment" || ! -f /etc/nix/nix.conf ]]; then
  echo "Generated cache trust or the installed Nix daemon configuration is missing." >&2
  exit 1
fi

echo "Installing public cache trust; existing Nix configuration will be backed up."
sudo -v
stamp="$(date +%Y%m%d%H%M%S)-$$"
sudo cp -p /etc/nix/nix.conf "/etc/nix/nix.conf.before-lan-cache.$stamp"
if [[ -e /etc/nix/lan-cache.conf ]]; then
  sudo cp -p /etc/nix/lan-cache.conf "/etc/nix/lan-cache.conf.before-lan-cache.$stamp"
fi
sudo install -o root -g wheel -m 0644 "$fragment" /etc/nix/lan-cache.conf
if ! grep -qxF '!include /etc/nix/lan-cache.conf' /etc/nix/nix.conf; then
  printf '\n!include /etc/nix/lan-cache.conf\n' \
    | sudo tee -a /etc/nix/nix.conf >/dev/null
fi
sudo launchctl kickstart -k system/org.nixos.nix-daemon
home-manager switch -b "before-cache-$stamp" --flake .#'p@pb-mb'
echo "Mac cache downloads are configured. Uploads require the server helpers."
