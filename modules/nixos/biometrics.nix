{ config, lib, pkgs, variables, ... }:
let
  cfg = variables.biometrics or { enable = false; };
  enabled = cfg.enable or false;
in
{
  # ── Fingerprint reader (Synaptics Prometheus, 06cb:00fc) ─────────────────
  services.fprintd.enable = lib.mkIf enabled true;

  # ── Face auth (IR camera, howdy) ─────────────────────────────────────────
  # services.howdy.enable auto-wires pam_howdy into all PAM services.
  # IR emitter must be configured once after first boot:
  #   sudo -E linux-enable-ir-emitter configure
  # Retire linux-enable-ir-emitter if the Chicony IR emitter is ever enabled
  # by the kernel/firmware without the userspace helper.
  services.howdy = lib.mkIf enabled {
    enable = true;
    control = lib.mkDefault "sufficient";
    settings.video.device_path = lib.mkDefault "/dev/video2";
  };

  services.linux-enable-ir-emitter = lib.mkIf enabled {
    enable = true;
    device = "video2";
  };

  # ── PAM wiring + auth order: face → fingerprint → password ──────────────
  security.pam.services = lib.mkIf enabled {
    login.fprintAuth = lib.mkDefault true;
    sudo.fprintAuth  = lib.mkDefault true;
    ly.fprintAuth    = lib.mkDefault true;
    login.rules.auth.howdy.order =
      config.security.pam.services.login.rules.auth.fprintd.order - 10;
    sudo.rules.auth.howdy.order =
      config.security.pam.services.sudo.rules.auth.fprintd.order - 10;
    ly.rules.auth.howdy.order =
      config.security.pam.services.ly.rules.auth.fprintd.order - 10;

    # Bitwarden biometric unlock: polkit calls this PAM service to verify the
    # user before releasing the vault key. Wire in the same biometric stack.
    # Retire if bitwarden-desktop ever ships its own PAM service file.
    bitwarden = {
      fprintAuth = lib.mkDefault true;
      rules.auth.howdy.order =
        config.security.pam.services.login.rules.auth.fprintd.order - 10;
    };
  };

  # ── Bitwarden polkit policy ───────────────────────────────────────────────
  # bitwarden-desktop is installed via home-manager, so its share/polkit-1
  # directory isn't picked up by the system polkit aggregation. Install the
  # policy at the NixOS level so polkit can authorize biometric unlock.
  # Retire when bitwarden-desktop moves to environment.systemPackages or
  # NixOS polkit starts scanning HM packages.
  security.polkit.extraConfig = lib.mkIf enabled ''
    // Allow the active user to unlock Bitwarden via biometrics (polkit action
    // com.bitwarden.Bitwarden.unlock). The desktop_proxy calls this action;
    // polkit then calls pam_authenticate on the "bitwarden" PAM service.
    // This just permits the action for the active session — PAM does the
    // actual biometric verification.
  '';

  environment.etc."polkit-1/localauthority/50-local.d/bitwarden-biometrics.pkla" = lib.mkIf enabled {
    text = ''
      [Bitwarden Biometric Unlock]
      Identity=unix-user:*
      Action=com.bitwarden.Bitwarden.unlock
      ResultActive=auth_self
    '';
  };

  # Install the polkit policy from the bitwarden-desktop package system-wide.
  environment.pathsToLink = lib.mkIf enabled [ "/share/polkit-1" ];
  environment.systemPackages = lib.mkIf enabled [ pkgs.bitwarden-desktop ];
}
