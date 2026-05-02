# File manager — Thunar (XFCE) plus the gvfs/udisks2 plumbing that
# lets it mount and browse removable media (USB sticks, SD cards,
# phones via MTP) without sudo.
#
# Cross-class footprint:
#   - flake.modules.nixos.file-manager — turns on the system services
#     Thunar relies on for mount/trash/network access:
#       * services.gvfs.enable  — gvfs daemons (gvfsd-trash, gvfsd-mtp,
#         gvfsd-smb, etc.) so Thunar's "Trash" folder, MTP phone
#         browsing, and SMB shares all work.
#       * services.udisks2.enable — udisks2 daemon for block-device
#         mount/unmount. The default polkit rule shipped by udisks2
#         lets any active local session mount removable media without
#         a password prompt, so kid accounts on pb-t480 can mount a
#         USB stick from Thunar even without polkit-agent. Static
#         (non-removable) drive operations still require auth.
#   - flake.modules.homeManager.file-manager — installs Thunar plus:
#       * gvfs           backend client lib (Thunar links against it)
#       * thunar-volman  auto-mount on insert / handle removable media
#       * thunar-archive-plugin  right-click "Extract" for zip/tar
#         archives, useful for kid robotics workflows where firmware
#         and example projects come as zips.
#
# Why XFCE Thunar (not Nautilus):
#   - Smaller closure (~80MB vs ~150MB for nautilus).
#   - Doesn't pull in the GNOME settings daemon or tracker indexer.
#   - Reliable USB drive mount/unmount via udisks2 — actually was the
#     specific request that prompted this module.
#   - Works on every wayland compositor without GNOME-specific quirks.
#
# Why a dedicated module (not absorbed into desktop-extras):
# desktop-extras is a kitchen sink that adult and kid bundles both
# want. file-manager has a system-side requirement (gvfs/udisks2)
# that would force every desktop-extras importer to also configure
# system services. Splitting keeps desktop-extras pure-HM.
#
# Pattern A enable: hosts/bundles opt in by importing the relevant
# class. Currently consumed by the kid bundle (HM) plus pb-t480
# (NixOS half).
#
# Retire when: a different file manager is chosen across the flake,
#   OR Thunar's auto-mount story regresses such that udisks2/gvfs
#   stop being the canonical answer.
{
  flake.modules.nixos.file-manager = { lib, ... }: {
    services.gvfs.enable = lib.mkDefault true;
    services.udisks2.enable = lib.mkDefault true;
  };

  flake.modules.homeManager.file-manager = { pkgs, ... }: {
    home.packages = with pkgs; [
      thunar
      thunar-volman
      thunar-archive-plugin
      gvfs
      # Thunar uses xarchiver as the default extract/create archive
      # backend (invoked by thunar-archive-plugin). Without it the
      # right-click "Extract Here" option silently no-ops.
      xarchiver
    ];
  };
}
