# Fonts — system font packages + fontconfig defaultFonts (NixOS) and
# user-level rendering policy / font installation (home-manager). Also
# sets the console (kernel framebuffer + TTY + Ly) font, which has to be
# a PSF bitmap (FantasqueSansM can't render in the kernel console).
#
# Cross-class footprint:
#   - flake.modules.nixos.fonts — installs Noto / Inter / Fantasque
#     Sans Mono (Nerd-Font-patched) and sets defaultFonts per family
#     (mono → FantasqueSansM, sans → Inter, etc.).
#     Also sets console.font to Cozette (bitmap NF-patched).
#   - flake.modules.homeManager.fonts — cross-platform:
#       · Linux  — turns on fontconfig in HM and drops a
#                  10-rendering.conf with slight hinting + RGB-off.
#                  Font *packages* come from the NixOS side, so HM
#                  installs none.
#       · Darwin — there is no NixOS side, and macOS uses Core Text
#                  (not fontconfig), so HM installs the same font
#                  package set into the profile and copies every
#                  face into ~/Library/Fonts/HomeManager/ where Core
#                  Text picks them up (copies, not symlinks — Core Text
#                  ignores symlinked font files). fontconfig is skipped.
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
# Retire when: the chosen font stack (Fantasque Sans Mono / Inter / Noto
#   / nerd variants) changes substantially, OR NixOS upstream ships sane
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
    # FantasqueSansM — Fantasque Sans Mono, Nerd-Font-patched. The single
    # coding + icon font used everywhere (terminals, waybar, editors).
    # fontconfig (Linux) / Core Text (macOS) picks the variant by family
    # name.
    nerd-fonts.fantasque-sans-mono
  ];
in
{
  flake.modules.nixos.fonts = { pkgs, ... }: {
    fonts = {
      packages = fontPkgs pkgs;
      fontconfig.defaultFonts = {
        # FantasqueSansM **Mono** — the single coding/icon font. The Mono
        # variant forces every glyph — including the Nerd icons — into a
        # single fixed-width cell; the bare "FantasqueSansM Nerd Font"
        # leaves the patched glyphs at their original (often 1.5–2×)
        # advance, which breaks monospace alignment (overlapping/clipped
        # letters) in terminals and other cell-grid clients. No secondary
        # coding font: if a glyph is truly absent fontconfig falls back to
        # the system defaults (Noto) automatically.
        monospace = [ "FantasqueSansM Nerd Font Mono" ];
        sansSerif = [ "Inter" ];
        serif = [ "Noto Serif" ];
        emoji = [ "Noto Color Emoji" ];
      };
    };

    # Console font — shown in the kernel boot log, the text-mode TTYs
    # (Ctrl+Alt+F1…F6), and inherited by Ly (TUI display manager).
    # The kernel framebuffer console only renders PSF bitmap fonts,
    # not TTF/OTF, so FantasqueSansM Nerd Font (used everywhere else in
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

        # Fantasque omits some Unicode glyphs. An unconstrained fallback can
        # pick proportional faces such as Inter or DejaVu Sans, whose glyphs
        # may be wider than a terminal cell and overlap adjacent text. Keep
        # every missing glyph on the terminal grid by preferring Noto Sans
        # Mono, while retaining Fantasque for everything it provides.
        xdg.configFile."fontconfig/conf.d/15-fantasque-fallback.conf".text = ''
          <?xml version="1.0"?>
          <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
          <fontconfig>
            <match target="pattern">
              <test name="family" compare="eq">
                <string>FantasqueSansM Nerd Font Mono</string>
              </test>
              <edit name="family" mode="append">
                <string>Noto Sans Mono</string>
              </edit>
            </match>
          </fontconfig>
        '';

        # Fantasque Sans Mono's next real face after Regular is Bold, which
        # is a much larger jump than wanted here. Synthetic emboldening adds
        # a restrained amount of stroke weight to Alacritty's Regular face
        # without changing Waybar, editors, or any other fontconfig client.
        xdg.configFile."fontconfig/conf.d/20-alacritty-embolden.conf".text = ''
          <?xml version="1.0"?>
          <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
          <fontconfig>
            <match target="font">
              <test name="prgname" compare="eq">
                <string>alacritty</string>
              </test>
              <test name="family" compare="eq">
                <string>FantasqueSansM Nerd Font Mono</string>
              </test>
              <test name="style" compare="eq">
                <string>Regular</string>
              </test>
              <edit name="embolden" mode="assign"><bool>true</bool></edit>
            </match>
          </fontconfig>
        '';
      })

      # ── Darwin: install faces into the HM profile ────────────────
      # No NixOS side on macOS, and Core Text (not fontconfig) is the
      # font subsystem. Putting the faces in `home.packages` is enough:
      # home-manager's built-in Darwin font handling rsyncs every face
      # from the profile into ~/Library/Fonts/HomeManager/ (the
      # `.home-manager-fonts-version` onChange hook, `rsync -acL` =
      # real-file copies, `--delete` for idempotent pruning). Core Text
      # scans that dir and picks the faces up.
      #
      # We deliberately do NOT hand-roll an activation that links/copies
      # into the same dir: an earlier custom `linkDarwinFonts` step did
      # `ln -sf` and, because it ran on every activation while the HM
      # rsync only runs on font-set changes, it kept clobbering HM's
      # good copies with symlinks — which Core Text silently ignores, so
      # zero faces registered (`system_profiler SPFontsDataType` listed
      # none). Relying on the HM built-in avoids that fight entirely.
      (lib.mkIf pkgs.stdenv.isDarwin {
        home.packages = fontPkgs pkgs;
      })
    ];
}
