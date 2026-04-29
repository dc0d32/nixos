{ config, lib, pkgs, variables, ... }:
let
  cfg = variables.biometrics or { enable = false; };
  enabled = cfg.enable or false;

  # IR-camera autodetect helper. Walks /dev/video* and picks the first node
  # whose v4l2 capabilities advertise it as an "infrared" device. Falls back
  # to the configured devicePath if nothing matches. Howdy reads the path
  # from /etc/howdy/config.ini, which is rewritten on every boot by the
  # systemd unit defined further down.
  cameraDevice = cfg.cameraDevice or "/dev/video2";
in
{
  # ── Fingerprint reader (Synaptics Prometheus, 06cb:00fc) ─────────────────
  services.fprintd.enable = lib.mkIf enabled true;

  # ── Face auth (IR camera, howdy) ─────────────────────────────────────────
  # services.howdy.enable auto-wires pam_howdy into the standard PAM stacks
  # (login, sudo, ly, etc.) at security.pam.services.<name>.howdy.enable.
  # IR emitter must be configured once after first boot:
  #   sudo -E linux-enable-ir-emitter configure
  # device_path is overwritten at boot by udev-howdy-camera.service below
  # (see Camera autodetect section). The static value here is just the
  # initial / fallback in case autodetect finds nothing.
  services.howdy = lib.mkIf enabled {
    enable = true;
    control = lib.mkDefault "sufficient";
    settings.video.device_path = lib.mkDefault cameraDevice;
  };

  services.linux-enable-ir-emitter = lib.mkIf enabled {
    enable = true;
    # Strip the /dev/ prefix; the option takes a bare device name.
    device = lib.removePrefix "/dev/" cameraDevice;
  };

  # ── PAM auth ordering (closest practical analogue to Windows Hello UX) ───
  #
  # The default NixOS biometric stack runs `auth sufficient pam_howdy.so`
  # and `auth sufficient pam_fprintd.so` BEFORE `auth sufficient pam_unix.so`.
  # That means PAM blocks on the fingerprint sensor (a synchronous read) for
  # several seconds even when the user has already typed a password — the
  # password line is unreachable until fprintd returns.
  #
  # We override the `order` of the howdy and fprintd rules so they run AFTER
  # `auth sufficient pam_unix.so try_first_pass`. Because pam_unix is
  # `sufficient`, a correct typed password short-circuits the rest of the
  # stack and biometric modules never run. If no password was typed (or the
  # password is wrong), pam_unix returns failure and PAM falls through to
  # howdy (face) and then fprintd (finger).
  #
  # The pam_deny rule MUST stay last in the auth stack — if howdy/fprintd
  # are placed after deny, biometrics become unreachable. Different services
  # have different default deny orders (login/ly: 13700; sudo/bitwarden:
  # 12500), and we don't want to relocate deny — that risks breaking other
  # auth modules between unix and deny. Instead we push deny to a fixed
  # position above ours, so the resolved order is always:
  #   ... unix-early, [keyring], unix(sufficient), howdy, fprintd, deny.
  #
  # As a side effect this also fixes the gnome-keyring "vault locked" prompt
  # after login: pam_unix-early (optional, likeauth) captures the password
  # into PAM_AUTHTOK before any auth module short-circuits, and
  # pam_gnome_keyring (optional) consumes that token to unlock the login
  # keyring. With the old ordering, fprintd/howdy at lower orders would
  # short-circuit first and the keyring never saw a password.
  #
  # Apply the same reorder to login (TTY), sudo, ly (display manager), and
  # bitwarden (polkit-driven biometric unlock).
  security.pam.services = lib.mkIf enabled (
    let
      # Slot howdy and fprintd between pam_unix (12900) and pam_deny.
      howdyOrder = 12950;
      fprintdOrder = 13000;
      denyOrder = 13100;
      reorder = {
        rules.auth = {
          howdy.order = howdyOrder;
          fprintd.order = fprintdOrder;
          # Force deny last so we don't get stranded behind it on services
          # whose default deny is at 12500 (sudo, bitwarden).
          deny.order = denyOrder;
        };
      };
    in
    {
      login = reorder // { fprintAuth = lib.mkDefault true; };
      sudo = reorder // { fprintAuth = lib.mkDefault true; };
      ly = reorder // { fprintAuth = lib.mkDefault true; };

      # Bitwarden biometric unlock: polkit calls this PAM service to verify
      # the user before releasing the vault key. Same biometric stack, same
      # ordering — password first, biometrics as fallback.
      # Retire if bitwarden-desktop ever ships its own PAM service file.
      bitwarden = reorder // { fprintAuth = lib.mkDefault true; };

      # ── Quickshell lockscreen: split PAM services for parallel auth ──────
      # The default "login" PAM stack runs sequentially (unix → howdy →
      # fprintd → deny). With pam_unix as `sufficient`, PAM immediately asks
      # for a password and only falls through to biometrics if pam_unix
      # returns ignore (no password provided). That serial behavior makes it
      # impossible for the lockscreen to *concurrently* try biometrics while
      # the user types a password.
      #
      # Solution: split the auth stack into two single-purpose PAM services
      # so quickshell can drive two parallel PamContexts (one for each).
      # Whichever one returns success first wins; the other is aborted.
      #
      # IMPORTANT: PAM resolves bare module names (`pam_howdy.so`) relative
      # to linux-pam's *own* `lib/security/` directory — which only contains
      # the modules linux-pam itself ships (pam_unix, pam_deny, etc.).
      # Modules from other packages (howdy, fprintd, gnome-keyring) live in
      # their own store paths and must be referenced absolutely, otherwise
      # PAM logs "unable to dlopen ... cannot open shared object file" and
      # treats the rule as a faulty module (which fails closed). The other
      # NixOS-managed PAM services (login/sudo/ly) avoid this because their
      # `rules.auth.<name>` entries are auto-prefixed by the framework with
      # the right store path; raw `text =` stacks must do it themselves.
      quickshell-password = {
        # Password-only: pam_unix verifies, pam_gnome_keyring captures the
        # token to unlock the keyring on success. No biometrics.
        text = ''
          auth      required  pam_unix.so       likeauth nullok try_first_pass
          auth      optional  ${pkgs.gnome-keyring}/lib/security/pam_gnome_keyring.so use_authtok
          account   required  pam_unix.so
          password  required  pam_unix.so       sha512 shadow nullok try_first_pass
          password  optional  ${pkgs.gnome-keyring}/lib/security/pam_gnome_keyring.so use_authtok
          session   required  pam_unix.so
          session   optional  ${pkgs.gnome-keyring}/lib/security/pam_gnome_keyring.so auto_start
        '';
      };
      quickshell-biometric = {
        # Biometric-only: try howdy (face) then fprintd (finger). pam_deny
        # last so failure of both yields a clean PamResult.Failed instead of
        # hanging. No password module — this PamContext should never set
        # responseRequired.
        text = ''
          auth      sufficient  ${pkgs.howdy}/lib/security/pam_howdy.so
          auth      sufficient  ${pkgs.fprintd}/lib/security/pam_fprintd.so
          auth      required    pam_deny.so
          account   required    pam_unix.so
          password  required    pam_deny.so
          session   required    pam_unix.so
        '';
      };
    }
  );

  # ── Camera autodetect ────────────────────────────────────────────────────
  # USB enumeration order is not stable: the Chicony IR camera may land on
  # /dev/video0, /dev/video2, /dev/video4, etc. depending on boot timing.
  # Hardcoding device_path = "/dev/video2" in howdy's config breaks face
  # unlock whenever the kernel renumbers the v4l2 nodes.
  #
  # Workaround: at boot (after systemd-udev-settle) walk /dev/video* and
  # pick the first node that v4l2-ctl reports as having the
  # V4L2_CAP_META_CAPTURE | infrared capability flag, falling back to
  # device-name match for "infrared" / "IR". Rewrite /etc/howdy/config.ini
  # in-place so howdy sees the right device on its next invocation.
  #
  # Retire when nixpkgs services.howdy gets a `device.autodetect = true`
  # option, or when the kernel/firmware exposes a stable /dev/v4l/by-id/
  # symlink for the IR camera (currently unreliable on this hardware).
  systemd.services.howdy-camera-autodetect = lib.mkIf enabled {
    description = "Auto-detect IR camera device path for howdy";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udev-settle.service" ];
    wants = [ "systemd-udev-settle.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.v4l-utils pkgs.gnused pkgs.coreutils pkgs.gawk ];
    script = ''
      set -eu
      cfg=/etc/howdy/config.ini

      pick_ir_device() {
        for dev in /dev/video*; do
          [ -e "$dev" ] || continue
          # v4l2-ctl --device "$dev" --info prints "Card type" and capability
          # flags; an IR camera typically advertises "Infrared" in its name
          # and lacks the standard "Video Capture" formats a color cam has.
          info=$(v4l2-ctl --device "$dev" --info 2>/dev/null || true)
          name=$(printf '%s' "$info" | awk -F': ' '/Card type/ {print $2; exit}')
          # Match common IR-camera name fragments (Chicony, Realtek IR,
          # generic "Infrared"). Case-insensitive.
          case "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" in
            *infrared*|*"ir camera"*|*"ir cam"*|*hellocam*)
              echo "$dev"
              return 0
              ;;
          esac
        done
        return 1
      }

      detected=$(pick_ir_device || true)
      if [ -z "$detected" ]; then
        echo "howdy-camera-autodetect: no IR-capable /dev/video* found, leaving howdy config untouched" >&2
        exit 0
      fi
      echo "howdy-camera-autodetect: selected $detected" >&2

      # Rewrite the device_path line in /etc/howdy/config.ini in-place. The
      # file is a symlink into /nix/store, so we need to break the link and
      # write a real file. mktemp + atomic mv keeps the operation safe.
      if [ -L "$cfg" ] || [ -f "$cfg" ]; then
        tmp=$(mktemp)
        sed "s|^device_path = .*|device_path = $detected|" "$cfg" > "$tmp"
        # Replace symlink/file with the rewritten copy.
        rm -f "$cfg"
        mv "$tmp" "$cfg"
        chmod 0644 "$cfg"
      fi
    '';
  };

  # ── Bitwarden polkit policy ──────────────────────────────────────────────
  # bitwarden-desktop is installed via home-manager, so its share/polkit-1
  # directory isn't picked up by the system polkit aggregation. Install the
  # policy at the NixOS level so polkit can authorize biometric unlock.
  # Retire when bitwarden-desktop moves to environment.systemPackages or
  # NixOS polkit starts scanning HM packages.
  #
  # The rule below tells polkit to require user re-auth for the bitwarden
  # unlock action. polkit then invokes pam_authenticate on the "bitwarden"
  # PAM service (see security.pam.services.bitwarden above), which runs the
  # full biometric stack (password → howdy → fprintd).
  #
  # This replaces the deprecated localauthority .pkla format with a modern
  # rules.d JS rule (the .pkla loader is going away in polkit ≥ 0.121).
  security.polkit.extraConfig = lib.mkIf enabled ''
    polkit.addRule(function (action, subject) {
      if (action.id == "com.bitwarden.Bitwarden.unlock" && subject.active) {
        return polkit.Result.AUTH_SELF;
      }
    });
  '';

  # Install the polkit policy from the bitwarden-desktop package system-wide.
  environment.pathsToLink = lib.mkIf enabled [ "/share/polkit-1" ];
  environment.systemPackages = lib.mkIf enabled [
    pkgs.bitwarden-desktop
    pkgs.v4l-utils # `v4l2-ctl` for users running `face-doctor` or debugging
  ];
}
