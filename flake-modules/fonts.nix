# Fonts — system font packages + fontconfig defaultFonts (NixOS) and
# user-level rendering policy / font installation (home-manager). Also
# sets the console (kernel framebuffer + TTY + Ly) font, which has to be
# a PSF bitmap (RecMono can't render in the kernel console).
#
# Cross-class footprint:
#   - flake.modules.nixos.fonts — installs Noto / Inter / JetBrains
#     Mono / Recursive / nerd-fonts variants and sets defaultFonts
#     per family (mono → RecMonoCasual, sans → Inter, etc.). Also
#     sets console.font to Cozette (bitmap NF-patched).
#   - flake.modules.homeManager.fonts — cross-platform:
#       · Linux  — turns on fontconfig in HM and drops a
#                  10-rendering.conf with slight hinting + RGB-off.
#                  Font *packages* come from the NixOS side, so HM
#                  installs none.
#       · Darwin — there is no NixOS side, and macOS uses Core Text
#                  (not fontconfig), so HM installs the same font
#                  package set into the profile and symlinks every
#                  face into ~/Library/Fonts/HomeManager/ where Core
#                  Text picks them up. fontconfig is skipped.
#
# The shared face list lives in the `fontPkgs` factory below so the
# NixOS and Darwin sides never drift. Console-only `cozette` is NOT in
# it — it's a PSF bitmap for the kernel console, useless to Core Text /
# fontconfig.
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
let
  # Shared face list consumed by both the NixOS side (system font
  # packages) and the Darwin HM side (profile install + ~/Library/Fonts
  # symlinks). Takes the inner module's `pkgs` so each class resolves it
  # against its own platform's nixpkgs. Excludes console-only `cozette`.
  fontPkgs = pkgs: with pkgs; [
    noto-fonts
    noto-fonts-color-emoji # renamed from noto-fonts-emoji
    noto-fonts-cjk-sans
    inter
    jetbrains-mono
    nerd-fonts.jetbrains-mono
    nerd-fonts.fira-code
    # Rec Mono ships four variants (Casual/Linear/Duotone/
    # Semicasual) in one nixpkgs attr; fontconfig (Linux) / Core Text
    # (macOS) picks the variant by family name.
    nerd-fonts.recursive-mono
  ];
in
{
  flake.modules.nixos.fonts = { pkgs, ... }: {
    fonts = {
      packages = fontPkgs pkgs;
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
    # actually render. cozette6x13 is the legacy size; cozette12x26
    # is the HiDPI 2× variant. Paired with
    # boot.loader.systemd-boot.consoleMode = "max" (set in the host
    # bridges), the kernel framebuffer runs at native panel res, so
    # the small bitmap stays sharp instead of being blown up by a
    # low-res EFI mode.
    # The PSF lives at <pkgs.cozette>/share/consolefonts/cozette6x13.psfu;
    # console.font takes the bare name (no extension), and setfont
    # searches console.packages' share/consolefonts/ at activation.
    console = {
      packages = [ pkgs.cozette ];
      font = "cozette6x13";
      # earlySetup runs the font load in the initrd so the boot log
      # (not just post-stage-2 messages) renders in Cozette too.
      earlySetup = true;
    };
  };

  flake.modules.homeManager.fonts = { pkgs, lib, ... }:
    lib.mkMerge [
      # ── Linux: fontconfig rendering policy ───────────────────────
      # Font packages come from the NixOS side (flake.modules.nixos.fonts),
      # so HM installs none here — it only sets the per-user rendering
      # policy fontconfig reads at runtime.
      (lib.mkIf pkgs.stdenv.isLinux {
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
      })

      # ── Darwin: install faces + symlink into ~/Library/Fonts ──────
      # No NixOS side on macOS, and Core Text (not fontconfig) is the
      # font subsystem. Installing the faces into the HM profile is not
      # enough — macOS only scans a fixed set of font directories — so
      # an activation step mirrors every face into the user's
      # ~/Library/Fonts/HomeManager/ scan dir. Confining to a dedicated
      # subdir keeps the set self-contained and reversible: deleting
      # that one directory removes every flake-managed font and never
      # touches /Library/Fonts or the macOS system faces.
      (lib.mkIf pkgs.stdenv.isDarwin {
        home.packages = fontPkgs pkgs;

        home.activation.linkDarwinFonts =
          let
            # Single tree of all faces so the activation script has one
            # root to walk regardless of how many font drvs there are.
            fontEnv = pkgs.symlinkJoin {
              name = "pb-mb-fonts";
              paths = fontPkgs pkgs;
            };
          in
          lib.hm.dag.entryAfter [ "writeBoundary" ] ''
            fontDir="$HOME/Library/Fonts/HomeManager"
            # rm -rf + recreate is the simplest idempotent sync: stale
            # faces from a previously-larger set never linger.
            $DRY_RUN_CMD rm -rf $VERBOSE_ARG "$fontDir"
            $DRY_RUN_CMD mkdir -p $VERBOSE_ARG "$fontDir"
            # -L follows symlinkJoin's links so -type f matches the real
            # face files; .ttc covers Noto CJK's TrueType collections.
            # ln is pinned to coreutils so $VERBOSE_ARG (a GNU-style long
            # option) is always accepted, never macOS's BSD ln.
            ${pkgs.findutils}/bin/find -L "${fontEnv}/share/fonts" -type f \
              \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ttc' \) \
              -exec $DRY_RUN_CMD ${pkgs.coreutils}/bin/ln -sf $VERBOSE_ARG {} "$fontDir/" \;
          '';
      })
    ];
}
