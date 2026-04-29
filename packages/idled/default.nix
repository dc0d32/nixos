# idled — kernel-input idle daemon. See packages/idled/src/main.rs for why
# this exists (smithay #1892 / niri ext_idle_notifier_v1 breakage).
#
# Built from the local source tree. Wired into pkgs.idled via
# overlays/idled.nix, then consumed by modules/home/desktop/idle.nix as a
# user systemd service.
{ lib
, rustPlatform
, pkg-config
, makeWrapper
}:

rustPlatform.buildRustPackage {
  pname = "idled";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  cargoLock = {
    lockFile = ./Cargo.lock;
  };

  nativeBuildInputs = [ pkg-config makeWrapper ];

  # Pure Rust + linux ioctls (evdev) + dbus over UNIX socket (zbus). No C deps
  # required at build time, and no runtime libraries beyond glibc.

  meta = with lib; {
    description = "Kernel-input idle daemon (works around smithay ext_idle_notifier_v1 bug)";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "idled";
  };
}
