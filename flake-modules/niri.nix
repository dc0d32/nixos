# niri — scrollable-tiling Wayland compositor (cross-class).
#
# NixOS class:
#   - enables programs.niri, pulls in companion CLI tools
#   - wires xdg-portal to the gtk + wlr backends
#   - brings up dbus + polkit + power-profiles-daemon + upower
#   - disables the niri-flake polkit agent so our hyprpolkitagent
#     (HM-side) doesn't race with it
#
# homeManager class:
#   - imports inputs.niri.homeModules.niri
#   - the user-side niri config (the kdl file, keybinds, layout)
#
# App launcher (fuzzel), clipboard history (cliphist + fuzzel),
# screenshot picker (grim + slurp + satty), bar (waybar), notification
# daemon (mako), and lockscreen (swaylock-effects) are wired in
# flake-modules/desktop-shell.nix + flake-modules/lockscreen.nix.
# This module just binds keys to invoke them.
#
# Pattern A: hosts opt in by importing this module. Headless / WSL
# hosts simply don't import it, so inputs.niri's modules are never
# imported either — desktops that don't run niri don't pay the eval
#   cost.
#
# Retire when: the user switches Wayland compositor (hyprland, sway,
# etc.) or niri grows to the size of warranting a dedicated subtree.
{ ... }:
{
  flake.modules.nixos.niri = { inputs, lib, pkgs, ... }: {
    imports = [ inputs.niri.nixosModules.niri ];

    programs.niri.enable = true;

    # niri-flake's NixOS module defaults `programs.niri.package` to
    # `pkgs.niri-stable`, where `niri-stable` is a manually-bumped
    # input pin in niri-flake — not a moving branch. As of 2026-05
    # that pin is still on niri v25.08 (Aug 2025), even though
    # upstream has shipped v25.11 and v26.04 (blur, Alt-Tab, true
    # maximize, fullscreen animations, …). niri-flake's
    # `niri-unstable` input, by contrast, follows niri's main and is
    # refreshed daily by mergify, so it currently provides v26.04+.
    #
    # Switching to niri-unstable here means we get fresh niri
    # releases on the same cadence as niri-flake's nightly bumps,
    # without waiting for the maintainer to manually advance the
    # niri-stable pin. Cachix coverage (niri.cachix.org) is the same
    # for both packages.
    #
    # We pull the package directly from niri-flake's outputs (rather
    # than `pkgs.niri-unstable`) because niri-flake exposes its
    # niri-{stable,unstable} via a `niri` overlay that the NixOS
    # module does not auto-apply to system pkgs.
    #
    # Retire when: niri-flake's niri-stable pin catches up to (or
    # surpasses) the niri-unstable revision we'd otherwise want, and
    # we no longer care about being on the bleeding edge.
    programs.niri.package =
      inputs.niri.packages.${pkgs.stdenv.hostPlatform.system}.niri-unstable;

    # Useful companions
    environment.systemPackages = with pkgs; [
      wl-clipboard
      wlr-randr
      brightnessctl
      playerctl
      grim
      slurp
      mako
      xdg-utils
    ];

    xdg.portal = {
      enable = true;
      extraPortals = with pkgs; [
        xdg-desktop-portal-gtk
        xdg-desktop-portal-wlr # screenshare/screencast for wlroots compositors
      ];
      # Without an explicit config, xdg-desktop-portal matches
      # backends by UseIn= in *.portal files. Both gtk.portal and
      # gnome.portal declare UseIn=gnome, which is wrong for niri
      # and causes gnome-portal to be activated alongside (or
      # instead of) gtk-portal, leading to startup races and timeout
      # failures. Pin niri to the gtk backend explicitly, using wlr
      # for screencast.
      config.niri = {
        default = [ "gtk" ];
        "org.freedesktop.impl.portal.ScreenCast" = [ "wlr" ];
        "org.freedesktop.impl.portal.Screenshot" = [ "wlr" ];
      };
    };

    services.dbus.enable = true;
    security.polkit.enable = true;
    services.power-profiles-daemon.enable = lib.mkDefault true;

    # UPower daemon — provides org.freedesktop.UPower over system
    # dbus for waybar's battery module (and any other consumer that
    # walks UPower for battery state). Safe to leave on for desktops
    # without a battery (UPower simply reports no laptop battery and
    # the waybar battery module hides itself).
    services.upower.enable = lib.mkDefault true;

    # niri-flake auto-installs polkit-kde-authentication-agent-1 as
    # a user systemd unit (niri-flake-polkit.service,
    # WantedBy=niri.service). We already run hyprpolkitagent
    # ourselves (see flake-modules/polkit-agent.nix); two
    # agents racing on the same dbus subject yields
    #   "Cannot register authentication agent: ... agent already
    #    exists for the given subject"
    # and the loser flaps until systemd's restart counter trips,
    # leaving the user session degraded. Disable the niri-flake
    # one. Documented opt-out per niri-flake README.
    systemd.user.services.niri-flake-polkit.enable = false;
  };

  flake.modules.homeManager.niri = { config, options, inputs, lib, pkgs, ... }: {
    imports = [ inputs.niri.homeModules.niri ];

    # niri-flake's home-manager module defaults `programs.niri.package`
    # to `niri-stable` (v25.08 as of 2026-05) — the same manually-pinned
    # commit the NixOS module would default to. We've explicitly pinned
    # the NixOS-side package to `niri-unstable` (see the comment in
    # `flake.modules.nixos.niri` above), and the HM module *must* track
    # that same version, because:
    #
    #   1. niri-flake's HM module runs `<cfg.package>/bin/niri validate`
    #      on the rendered config.kdl as part of the build. If HM's
    #      `cfg.package` is older than the system niri, any config that
    #      uses newer KDL nodes (e.g. `background-effect` from v26.04)
    #      will fail validation at HM build time, even though the
    #      actual running niri (the system one) accepts it.
    #   2. Drift between the two would also mean the version of
    #      `niri msg` referenced from HM-installed scripts could differ
    #      from the running compositor's IPC schema.
    #
    # Retire when: niri-flake's `niri-stable` pin catches up to the
    # niri-unstable revision the NixOS module is already on.
    programs.niri.package =
      inputs.niri.packages.${pkgs.stdenv.hostPlatform.system}.niri-unstable;

    # ── Wayland session env propagation ─────────────────────────
    # niri does not natively push WAYLAND_DISPLAY / XDG_CURRENT_DESKTOP
    # into the user systemd manager or D-Bus activation environment.
    # Without this, every user systemd unit that needs a Wayland
    # connection (awww-daemon, easyeffects, anything graphical-
    # session.target-bound) starts before the env is set, fails to
    # connect to the compositor, and crashes — typically with
    # "WAYLAND_DISPLAY is not set" or socket-not-found errors.
    #
    # The canonical fix (per niri-flake README, sway/hyprland conventions)
    # is to run dbus-update-activation-environment with --systemd at
    # session start; this single call:
    #   1. registers the listed env vars with the user D-Bus daemon so
    #      D-Bus-activated services see them, and
    #   2. propagates them into `systemctl --user` via systemd's own
    #      env-import mechanism.
    # graphical-session.target then has the right env when its wanted
    # services start.
    #
    # Variables propagated: WAYLAND_DISPLAY (the obvious one),
    # XDG_CURRENT_DESKTOP (used by xdg-portal backend selection,
    # gtk theming, and the per-compositor branches in many apps).
    #
    # mkBefore so this env-propagation runs FIRST, before all the
    # other spawn-at-startup entries (polkit-agent,
    # waybar, mako, etc.) — those depend on the env having
    # been pushed.
    #
    # Retire when: niri grows native systemd-import behaviour at
    # session start (tracked in niri upstream; not present as of 25.08).
    programs.niri.settings.spawn-at-startup = lib.mkBefore [
      {
        command = [
          "${pkgs.dbus}/bin/dbus-update-activation-environment"
          "--systemd"
          "WAYLAND_DISPLAY"
          "XDG_CURRENT_DESKTOP"
        ];
      }
    ];

    programs.niri.settings = {
      input.keyboard = {
        xkb.layout = "us";
        repeat-delay = 200;
        repeat-rate = 35;
      };
      input.touchpad = {
        tap = true;
        natural-scroll = true;
        accel-profile = "flat";
        # Slow scrolling — default 1.0 was way too fast on this trackpad;
        # Niri scales libinput scroll deltas by this factor for
        # both touchpad axes.
        scroll-factor = 0.4;
      };
      input.mouse = {
        accel-profile = "flat";
      };
      prefer-no-csd = true;
      hotkey-overlay = {
        skip-at-startup = true;
      };
      outputs = {
        "eDP-1" = {
          scale = 1;
        };
      };
      layout = {
        gaps = 2;
        border.width = 2;
      };
    };

    # ── Background blur (niri 26.04+, Window Effects) ───────────
    # Catch-all `background-effect { blur true; xray false; }` on
    # every window-rule and layer-rule. Opaque surfaces visually
    # swallow the effect (their own pixels cover the blurred
    # composite), so this only actually shows up where we've
    # intentionally made things translucent — the waybar bar (CSS
    # alpha < 1), fuzzel launcher, mako notifications, and the
    # per-app translucent windows (alacritty, VS Code, Chrome,
    # PiP). xray=false uses live-composite mode (blurs the actual
    # composite of whatever is below); flip to xray=true for the
    # cheaper wallpaper-only sample if GPU cost ever shows up.
    #
    # Why we go through `programs.niri.config` instead of
    # `programs.niri.settings.window-rules`: the niri-flake schema
    # (sodiboo/niri-flake, settings.nix) does not yet expose a
    # typed `background-effect` field on window-rule or layer-rule.
    # Verified against upstream HEAD as of 2026-05. So we render
    # the typed settings tree as normal, then append two raw KDL
    # nodes via niri-flake's exported `inputs.niri.lib.kdl.node`
    # constructor. niri-flake still runs `niri validate` on the
    # final concatenated config, so syntax errors fail the build.
    #
    # We read the default render via `options.programs.niri.config.default`
    # (the option's default is `settings.render cfg.settings`,
    # computed once); appending and reassigning would otherwise
    # cause infinite recursion.
    #
    # Why each `background-effect` block always has TWO children
    # (blur + xray) instead of just `blur`: niri-flake's KDL
    # serializer (kdl.nix:68-73 should-collapse) collapses any
    # chain of single-child nodes onto one line as
    # `window-rule { background-effect { blur true; }; }`. The
    # niri 26.04 KDL parser then mis-parses the inner `;` and
    # tries to treat `background-effect` as a top-level node,
    # erroring with `unexpected node \`background-effect\``.
    # Giving `background-effect` two children defeats the
    # collapse and forces multi-line output, which parses
    # correctly.
    #
    # Retire when: niri-flake's settings.nix grows a typed
    # `background-effect = { blur = true; xray = ...; }` field
    # on window-rule / layer-rule, OR niri-flake fixes the
    # should-collapse codepath. At that point, drop this block
    # and add `background-effect.blur = true;` to a catch-all
    # entry in `programs.niri.settings.window-rules` /
    # `…layer-rules`.
    programs.niri.config =
      let
        kdl = inputs.niri.lib.kdl;
        blurChild = kdl.node "background-effect" [ ] [
          (kdl.node "blur" [ true ] [ ])
          (kdl.node "xray" [ false ] [ ])
        ];
      in
      options.programs.niri.config.default ++ [
        (kdl.node "window-rule" [ ] [ blurChild ])
        (kdl.node "layer-rule" [ ] [ blurChild ])
      ];
  };
}
