# DisplayLink userspace driver — replace nixpkgs' `requireFile` src with
# a plain `fetchurl` from Synaptics' public download URL.
#
# WHY THIS EXISTS
# ---------------
# `pkgs.displaylink` is unfree AND marked non-redistributable, so nixpkgs
# deliberately sources it via `requireFile`: the zip must be downloaded by
# hand (after clicking through the EULA) and inserted into each machine's
# Nix store with `nix-prefetch-url` before the package will build.
#
# That is fundamentally incompatible with how this flake deploys:
#   * `nixos-anywhere` installs build the host closure on a machine that
#     has never seen the target, so the manual step cannot happen first;
#   * flake-modules/auto-upgrade.nix pulls and rebuilds unattended, and a
#     `requireFile` miss is a hard eval failure — a laptop would silently
#     stop upgrading until someone SSHed in and ran a prefetch by hand.
#
# The URL below is the exact one nixpkgs prints in its own `requireFile`
# message, it is public, unauthenticated, and hashes to precisely the
# value nixpkgs already expects (verified 2026-07-26). Substituting
# `fetchurl` therefore changes nothing about *what* is built — only about
# who does the downloading. Configuring this host to install DisplayLink
# is the act of accepting Synaptics' EULA.
#
# CAUTION: the resulting closure is non-redistributable. Never push it to
# a shared binary cache (cachix or otherwise). It is fine in the local
# store and fine to build on the target host.
#
# The version assertion below is deliberate: the URL is version-pinned
# ("2025-09", 6.2.0-30). When nixpkgs bumps `displaylink`, this overlay
# would otherwise silently pair a NEW evdi with an OLD userspace driver,
# which fails at runtime in confusing ways. Failing loudly at eval time
# with instructions is much kinder.
#
# RETIREMENT CONDITION
# --------------------
# Delete this file (and its entry in overlays/default.nix) when either:
#   * nixpkgs' `displaylink` stops using `requireFile` — e.g. Synaptics
#     relicenses to something redistributable, or nixpkgs grows an
#     accepted-EULA fetcher; OR
#   * every DisplayLink dock in the fleet has been replaced by a
#     DP-alt-mode / Thunderbolt dock, so nothing imports
#     flake.modules.nixos.displaylink any more.
final: prev:
let
  # Keep in lockstep with the URL below. See header.
  expectedVersion = "6.2.0-30";

  # Both from nixpkgs' own requireFile message for ${expectedVersion}.
  url = "https://www.synaptics.com/sites/default/files/exe_files/2025-09/DisplayLink%20USB%20Graphics%20Software%20for%20Ubuntu6.2-EXE.zip";
  hash = "sha256-JQO7eEz4pdoPkhcn9tIuy5R4KyfsCniuw6eXw/rLaYE=";
in
{
  displaylink =
    if prev.displaylink.version != expectedVersion then
      throw ''
        overlays/displaylink.nix is pinned to displaylink ${expectedVersion},
        but nixpkgs now provides ${prev.displaylink.version}.

        This overlay replaces the `requireFile` source with a `fetchurl` from
        a version-specific Synaptics URL, so the pin must be refreshed by hand:

          1. Read the new `requireFile` message for the URL + hash:
               nix log $(nix eval --raw nixpkgs#displaylink.drvPath) 2>/dev/null \
                 || nix build nixpkgs#displaylink
          2. Update `expectedVersion`, `url` and `hash` in
             overlays/displaylink.nix to match.
          3. Re-test on a host with a DisplayLink dock attached.

        Refusing to build rather than pairing a new evdi with a stale
        userspace driver.
      ''
    else
      prev.displaylink.overrideAttrs (_: {
        src = prev.fetchurl { inherit url hash; name = "displaylink-620.zip"; };
      });
}
