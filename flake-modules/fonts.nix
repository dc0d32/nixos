# Fonts — system font packages + fontconfig defaultFonts (NixOS) and
# user-level fontconfig rendering policy (home-manager). Also sets
# the console (kernel framebuffer + TTY + Ly) font, which has to be
# a PSF bitmap (RecMono can't render in the kernel console).
#
# Cross-class footprint:
#   - flake.modules.nixos.fonts — installs Noto / Inter / JetBrains
#     Mono / Recursive / nerd-fonts variants and sets defaultFonts
#     per family (mono → RecMonoCasual, sans → Inter, etc.). Also
#     sets console.font to Cozette (bitmap NF-patched).
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
# Retire when: the chosen font stack (Rec Mono / Inter / Noto / nerd
#   variants) changes substantially, OR NixOS upstream ships sane
#   default mono/sans/serif/emoji families and a fontconfig rendering
#   policy that match what this module produces.
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

    # Console font — shown in the kernel boot log, the text-mode TTYs
    # (Ctrl+Alt+F1…F6), and inherited by Ly (TUI display manager).
    # The kernel framebuffer console only renders PSF bitmap fonts,
    # not TTF/OTF, so RecMono Nerd Font (used everywhere else in
    # the GUI) cannot be used here. Cozette is the closest spiritual
    # match: a bitmap font with Nerd Font glyph patches, so the
    # NF-only icons that appear in journalctl / Ly status lines
    # actually render. cozette12x26 is the HiDPI variant
    # (12px wide × 26px tall); cozette6x13 is the legacy size.
    # The PSF lives at <pkgs.cozette>/share/consolefonts/cozette12x26.psfu;
    # console.font takes the bare name (no extension), and setfont
    # searches console.packages' share/consolefonts/ at activation.
    console = {
      packages = [ pkgs.cozette ];
      font = "cozette12x26";
      # earlySetup runs the font load in the initrd so the boot log
      # (not just post-stage-2 messages) renders in Cozette too.
      earlySetup = true;
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
