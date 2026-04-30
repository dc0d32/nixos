# Fonts — system font packages + fontconfig defaultFonts (NixOS) and
# user-level fontconfig rendering policy (home-manager).
#
# Cross-class footprint:
#   - flake.modules.nixos.fonts — installs Noto / Inter / JetBrains
#     Mono / Recursive / nerd-fonts variants and sets defaultFonts
#     per family (mono → RecMonoCasual, sans → Inter, etc.).
#   - flake.modules.homeManager.fonts — turns on fontconfig in HM and
#     drops a 10-rendering.conf with slight hinting + RGB-off.
#
# Pattern A: hosts opt in by importing this module on either class.
# Headless / WSL hosts simply don't import the NixOS side.
#
# Note on the rename: nerd fonts moved from the
# `pkgs.nerdfonts.override { fonts = [ ... ]; }` aggregate to
# individual attrs under `pkgs.nerd-fonts.<name>` in nixpkgs. Retire
# this comment once we're well past that transition.
#
# Migrated from modules/nixos/fonts.nix and modules/home/fonts.nix
# (the latter was already moved to flake-modules/fonts.nix in commit
# 1be551a — this commit folds the NixOS side in alongside it).
{ lib, ... }:
{
  flake.modules.nixos.fonts = { pkgs, ... }: {
    fonts = {
      packages = with pkgs; [
        noto-fonts
        noto-fonts-color-emoji # renamed from noto-fonts-emoji
        noto-fonts-cjk-sans
        inter
        jetbrains-mono
        nerd-fonts.jetbrains-mono
        nerd-fonts.fira-code
        # Rec Mono ships four variants (Casual/Linear/Duotone/
        # Semicasual) in one nixpkgs attr; fontconfig picks the
        # variant by family name below.
        nerd-fonts.recursive-mono
      ];
      fontconfig.defaultFonts = {
        # Rec Mono Casual first; fall back to JetBrainsMono if a
        # client can't find the patched family (e.g. pre-patched
        # tooling).
        monospace = [ "RecMonoCasual Nerd Font" "JetBrainsMono Nerd Font" ];
        sansSerif = [ "Inter" ];
        serif = [ "Noto Serif" ];
        emoji = [ "Noto Color Emoji" ];
      };
    };
  };

  flake.modules.homeManager.fonts = {
    # `mkDefault` on the fontconfig fields so a host can override
    # hinting style without a `mkForce` fight. The fontconfig snippet
    # under xdg.configFile is the actual policy file fontconfig reads
    # at runtime.
    fonts.fontconfig = {
      enable = lib.mkDefault true;
      hinting = lib.mkDefault "slight";
    };

    xdg.configFile."fontconfig/conf.d/10-rendering.conf".text = ''
      <?xml version="1.0"?>
      <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
      <fontconfig>
        <match target="font">
          <edit name="antialias" mode="assign"><bool>true</bool></edit>
          <edit name="hinting" mode="assign"><bool>true</bool></edit>
          <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
          <edit name="rgba" mode="assign"><const>none</const></edit>
          <edit name="lcdfilter" mode="assign"><const>lcdnone</const></edit>
        </match>
      </fontconfig>
    '';
  };
}
