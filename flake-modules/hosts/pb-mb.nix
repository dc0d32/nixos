# pb-mb — MacBook Air M4 (aarch64-darwin), userland-only.
#
# Naming: `pb-mb` = "pb" (initials) + "mb" (MacBook). Sibling to the
# bare-metal Linux laptops pb-x1 / pb-t480.
#
# Unlike every other host bridge in this repo, pb-mb declares NO
# `configurations.nixos.*` — it is a *standalone home-manager* config
# only. macOS is the base OS; this flake never owns the system. That is
# the deliberate, reversible model AGENTS.md keeps HM standalone for
# ("HM runs standalone so the same user modules can apply on macOS
# later"). Concretely:
#
#   - The Nix package manager itself (Determinate Systems installer on
#     Apple Silicon) owns the only system footprint: the /nix APFS
#     volume, the _nixbld* build users, and a few lines appended to
#     /etc/zshrc + /etc/bashrc. Removed wholesale by
#     `/nix/nix-installer uninstall`.
#   - This config writes ONLY under $HOME (~/.nix-profile,
#     ~/.config/home-manager, ~/.local/state/…, dotfile symlinks, and
#     per-user launchd agents under ~/Library/LaunchAgents). No sudo,
#     no /etc, no `defaults write`, no system launchd daemons. Removed
#     by `home-manager uninstall`.
#
# So "I don't want this anymore" is two commands back to vanilla macOS,
# no repave. nix-darwin is intentionally NOT used — it is the layer that
# mutates /etc, launchd daemons, and `defaults`, which is exactly the
# system-level footprint this host is built to avoid.
#
# What it imports: the cross-platform `dev` bundle (shells, git, gh,
# tmux, vim, btop, direnv, the ai-cli + build-deps tooling) plus a thin
# GUI slice (vscode) and the cross-platform `fonts` module (which, on
# darwin, installs the face set into the profile and mirrors it into
# ~/Library/Fonts/HomeManager/ for Core Text). Wayland desktop, audio,
# bluetooth, power/battery, biometrics, disko/impermanence/backup are
# Linux-only and deliberately absent. No alacritty here — macOS ships
# Terminal.app and the terminal of choice is the user's, not the flake's.
#
# Bootstrap on the Mac (after installing Nix + enabling flakes):
#   nix run home-manager/master -- switch --flake .#'p@pb-mb'
# Thereafter:
#   home-manager switch --flake .#'p@pb-mb'
#
# Retire when: the M4 Air is decommissioned, or the experiment is
#   abandoned (delete this file + `home-manager uninstall` +
#   `/nix/nix-installer uninstall` on the Mac).
{ config, ... }:
let
  hostName = "pb-mb";
  # Single source of truth for the account name; everything below
  # derives from it (config name, home.username, home.homeDirectory).
  # Kept as a literal (not env-derived) on purpose: standalone HM needs
  # these at eval time, and reading $USER/$HOME would force `--impure`
  # on every switch — a forget-the-flag landmine. This is the same
  # convention the Linux host bridges (pb-x1, m-pc, wsl) use.
  user = "p";
  system = "aarch64-darwin";
  stateVersion = "25.11";

  # HM pkgs instance via the shared factory in ../mk-pkgs.nix (overlays
  # + allowUnfree + allowAliases=false), resolved for aarch64-darwin.
  hmPkgs = config.flake.lib.mkPkgs system;
in
{
  # Note: this host sets NO top-level (flake-parts level) options. It
  # deliberately does NOT redeclare `git`/`locale` — those are
  # flake-parts singletons already set to this same author's identity by
  # the Linux host bridges, and redeclaring them with a different value
  # would conflict (same value would be redundant). pb-mb inherits them.

  configurations.homeManager."${user}@${hostName}" = {
    pkgs = hmPkgs;
    module = {
      imports = config.flake.lib.bundles.homeManager.dev ++ [
        # Thin GUI slice. vscode is a cross-platform HM module; the rest
        # of the desktop bundle (niri/waybar/mako/lockscreen/etc.) is
        # Wayland-only and excluded. alacritty is intentionally NOT here —
        # macOS uses its native terminal.
        config.flake.modules.homeManager.vscode
        # Fonts: on darwin this installs the face set + mirrors it into
        # ~/Library/Fonts/HomeManager/. See flake-modules/fonts.nix.
        config.flake.modules.homeManager.fonts
      ];

      # HM manages itself.
      programs.home-manager.enable = true;

      # Per-user session vars. Editor pinned to vim (flake-modules/vim.nix
      # sets defaultEditor=true but some shells/terminals don't pick that
      # up), matching the Linux hosts.
      home.sessionVariables = {
        EDITOR = "vim";
        VISUAL = "vim";
      };

      home.username = user;
      # macOS homes live under /Users, not /home.
      home.homeDirectory = "/Users/${user}";
      home.stateVersion = stateVersion;
    };
  };
}
