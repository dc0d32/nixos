# Biometrics — fingerprint reader (Synaptics Prometheus) + face auth
# (howdy via IR camera) + PAM stack reordering for face-first /
# password-first behavior + a Bitwarden polkit policy that pipes its
# unlock through the same biometric stack.
#
# Pattern A: hosts opt in by importing this module. The legacy
# `variables.biometrics.enable` gate is gone — importing IS enabling.
#
# Top-level option:
#   - biometrics.cameraDevice — fallback /dev/video* path used at
#     boot before the autodetect oneshot picks the real IR sensor.
#     Optional; defaults to /dev/video2 to match the legacy module.
#
# Migrated from modules/nixos/biometrics.nix.
{ lib, config, ... }:
let
  cfg = config.biometrics;
in
{
  options.biometrics = {
    cameraDevice = lib.mkOption {
      type = lib.types.str;
      default = "/dev/video2";
      description = ''
        IR camera device path used as the initial / fallback value in
        /etc/howdy/config.ini. The howdy-camera-autodetect systemd
        service rewrites this at boot once it walks /dev/video* and
        finds an IR-capable node.
      '';
    };
  };

  config.flake.modules.nixos.biometrics = { lib, pkgs, ... }: {
    # ── Fingerprint reader (Synaptics Prometheus, 06cb:00fc) ─────
    services.fprintd.enable = true;

    # ── Face auth (IR camera, howdy) ─────────────────────────────
    # services.howdy.enable auto-wires pam_howdy into the standard
    # PAM stacks (login, sudo, ly, etc.) at
    # security.pam.services.<name>.howdy.enable. IR emitter must be
    # configured once after first boot:
    #   sudo -E linux-enable-ir-emitter configure
    # device_path is overwritten at boot by udev-howdy-camera.service
    # below (see Camera autodetect section). The static value here is
    # just the initial / fallback in case autodetect finds nothing.
    services.howdy = {
      enable = true;
      control = lib.mkDefault "sufficient";
      settings.video.device_path = lib.mkDefault cfg.cameraDevice;

      # Allow darker rooms. The default `dark_threshold = 60` means
      # a frame is rejected if more than 60% of its pixels fall in
      # the lowest 1/8 of the histogram (i.e. the IR-illuminated
      # face has too little contrast against the background).
      # Raising to 85 accepts dimmer rooms; the false-accept risk
      # is unchanged because the actual face match still uses the
      # `certainty` threshold (3.5).
      # Source: howdy/src/config.ini comment on dark_threshold.
      # mkForce because upstream
      # nixos/modules/services/security/howdy pins this to 60 at
      # normal priority, so mkDefault loses the merge.
      settings.video.dark_threshold = lib.mkForce 85;
    };

    services.linux-enable-ir-emitter = {
      enable = true;
      # Strip the /dev/ prefix; the option takes a bare device name.
      device = lib.removePrefix "/dev/" cfg.cameraDevice;
    };

    # ── PAM auth ordering ────────────────────────────────────────
    #
    # The default NixOS biometric stack runs `auth sufficient
    # pam_howdy.so` and `auth sufficient pam_fprintd.so` BEFORE
    # `auth sufficient pam_unix.so`. That means PAM blocks on the
    # fingerprint sensor (a synchronous read) for several seconds
    # even when the user has already typed a password — the
    # password line is unreachable until fprintd returns.
    #
    # We override the `order` of howdy and fprintd so they slot
    # deliberately around `pam_unix`. There are two policies,
    # applied per-service:
    #
    #   "face-first"     (sudo, login, ly):
    #       howdy → pam_unix → fprintd → deny
    #     The IR camera is fast (~1s); leading with face gives a
    #     Windows Hello-style "look at the laptop and you're in"
    #     experience. Falls through to a typed password if the
    #     camera shot doesn't match, then to fingerprint as a
    #     slower last-resort biometric.
    #
    #   "password-first" (bitwarden):
    #       pam_unix → howdy → fprintd → deny
    #     Vault unlock is a deliberate gesture; we want the user to
    #     type a password rather than glance and have the vault
    #     open. Biometrics remain available as a fallback.
    #
    # Important caveats for "face-first" on login/ly:
    # `pam_unix-early` (optional, order 11700) and
    # `pam_gnome_keyring` (optional, order 12200) still run before
    # howdy *only if howdy is ordered above them*. On sudo there is
    # no keyring, so howdy can sit at the very top. On login/ly we
    # slot howdy at 12500 — above the keyring (12200), below the
    # *sufficient* pam_unix (12900) — so:
    #   1. unix-early(11700) tries to capture an AUTHTOK from any typed input.
    #   2. gnome_keyring(12200) consumes the AUTHTOK if present.
    #   3. howdy(12500) attempts face match; on success, short-circuits.
    #   4. unix(12900) prompts for password as fallback.
    #   5. fprintd(13000) prompts for finger as final fallback.
    #   6. deny(13100) — required-last sentinel so a complete fall-
    #      through yields a clean failure rather than landing on the
    #      next module.
    #
    # KEYRING CAVEAT: when face-login wins on login/ly, no password
    # is ever typed, so AUTHTOK is empty, and pam_gnome_keyring
    # cannot unlock the login keyring. The user will get a separate
    # "unlock keyring" prompt later when an app needs it. To get the
    # keyring auto-unlocked, type the password into ly/login instead
    # of using face.
    #
    # The pam_deny rule MUST stay last. Different services have
    # different default deny orders (login/ly: 13700; sudo/bitwarden:
    # 12500); we relocate deny to 13100 explicitly so we don't get
    # stranded behind it on sudo / bitwarden. Don't go below 13000
    # or fprintd becomes unreachable.
    security.pam.services =
      let
        mkReorder = { howdyOrder }: {
          rules.auth = {
            howdy.order = howdyOrder;
            fprintd.order = 13000;
            # Force deny last so we don't get stranded behind it on
            # services whose default deny is at 12500 (sudo,
            # bitwarden).
            deny.order = 13100;
          };
        };
        # Face-first for sudo: no keyring step to preserve, so
        # howdy can sit at the very top of the stack (below the
        # conventional 11000 account range used by
        # pam_unix-account, but above the auth pam_unix at 11700).
        reorderFaceFirstSudo = mkReorder { howdyOrder = 11500; };
        # Face-first for login/ly: leave room for unix-early(11700)
        # and gnome_keyring(12200) so the keyring gets an AUTHTOK
        # if a password *is* typed. Howdy slots between keyring and
        # the deciding pam_unix.
        reorderFaceFirstLogin = mkReorder { howdyOrder = 12500; };
        # Password-first for bitwarden: vault unlock should be a
        # deliberate password gesture; biometrics remain a fallback.
        reorderPasswordFirst = mkReorder { howdyOrder = 12950; };
      in
      {
        sudo = reorderFaceFirstSudo // { fprintAuth = lib.mkDefault true; };
        login = reorderFaceFirstLogin // { fprintAuth = lib.mkDefault true; };
        ly = reorderFaceFirstLogin // { fprintAuth = lib.mkDefault true; };

        # Bitwarden biometric unlock: polkit calls this PAM service
        # to verify the user before releasing the vault key.
        # Password-first; biometrics as fallback.
        # Retire if bitwarden-desktop ever ships its own PAM service file.
        bitwarden = reorderPasswordFirst // { fprintAuth = lib.mkDefault true; };

        # ── Quickshell lockscreen: split PAM services for parallel auth ──
        # The default "login" PAM stack runs sequentially (unix →
        # howdy → fprintd → deny). With pam_unix as `sufficient`,
        # PAM immediately asks for a password and only falls
        # through to biometrics if pam_unix returns ignore (no
        # password provided). That serial behavior makes it
        # impossible for the lockscreen to *concurrently* try
        # biometrics while the user types a password.
        #
        # Solution: split the auth stack into two single-purpose
        # PAM services so quickshell can drive two parallel
        # PamContexts (one for each). Whichever one returns success
        # first wins; the other is aborted.
        #
        # IMPORTANT: PAM resolves bare module names
        # (`pam_howdy.so`) relative to linux-pam's *own*
        # `lib/security/` directory — which only contains the
        # modules linux-pam itself ships (pam_unix, pam_deny,
        # etc.). Modules from other packages (howdy, fprintd,
        # gnome-keyring) live in their own store paths and must be
        # referenced absolutely, otherwise PAM logs "unable to
        # dlopen ... cannot open shared object file" and treats
        # the rule as a faulty module (which fails closed). The
        # other NixOS-managed PAM services (login/sudo/ly) avoid
        # this because their `rules.auth.<name>` entries are
        # auto-prefixed by the framework with the right store path;
        # raw `text =` stacks must do it themselves.
        quickshell-password = {
          # Password-only: pam_unix verifies, pam_gnome_keyring
          # captures the token to unlock the keyring on success.
          # No biometrics.
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
          # Biometric-only: try howdy (face) then fprintd (finger).
          # pam_deny last so failure of both yields a clean
          # PamResult.Failed instead of hanging. No password
          # module — this PamContext should never set
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
      };

    # ── Camera autodetect ────────────────────────────────────────
    # USB enumeration order is not stable: the Chicony IR camera
    # may land on /dev/video0, /dev/video2, /dev/video4, etc.
    # depending on boot timing. Hardcoding device_path =
    # "/dev/video2" in howdy's config breaks face unlock whenever
    # the kernel renumbers the v4l2 nodes.
    #
    # Workaround: at boot (after systemd-udev-settle) walk
    # /dev/video* and pick the first node that v4l2-ctl reports as
    # having the V4L2_CAP_META_CAPTURE | infrared capability flag,
    # falling back to device-name match for "infrared" / "IR".
    # Rewrite /etc/howdy/config.ini in-place so howdy sees the
    # right device on its next invocation.
    #
    # Retire when nixpkgs services.howdy gets a
    # `device.autodetect = true` option, or when the kernel/firmware
    # exposes a stable /dev/v4l/by-id/ symlink for the IR camera
    # (currently unreliable on this hardware).
    systemd.services.howdy-camera-autodetect = {
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
            # v4l2-ctl --device "$dev" --info prints "Card type" and
            # capability flags; an IR camera typically advertises
            # "Infrared" in its name and lacks the standard
            # "Video Capture" formats a color cam has.
            info=$(v4l2-ctl --device "$dev" --info 2>/dev/null || true)
            name=$(printf '%s' "$info" | awk -F': ' '/Card type/ {print $2; exit}')
            # Match common IR-camera name fragments (Chicony,
            # Realtek IR, generic "Infrared"). Case-insensitive.
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

        # Rewrite the device_path line in /etc/howdy/config.ini
        # in-place. The file is a symlink into /nix/store, so we
        # need to break the link and write a real file. mktemp +
        # atomic mv keeps the operation safe.
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

    # ── Bitwarden polkit policy ──────────────────────────────────
    # bitwarden-desktop is installed via home-manager, so its
    # share/polkit-1 directory isn't picked up by the system polkit
    # aggregation. Install the policy at the NixOS level so polkit
    # can authorize biometric unlock.
    # Retire when bitwarden-desktop moves to environment.
    # systemPackages or NixOS polkit starts scanning HM packages.
    #
    # The rule below tells polkit to require user re-auth for the
    # bitwarden unlock action. polkit then invokes pam_authenticate
    # on the "bitwarden" PAM service (see security.pam.services.
    # bitwarden above), which runs the full biometric stack
    # (password → howdy → fprintd).
    #
    # This replaces the deprecated localauthority .pkla format with
    # a modern rules.d JS rule (the .pkla loader is going away in
    # polkit ≥ 0.121).
    security.polkit.extraConfig = ''
      polkit.addRule(function (action, subject) {
        if (action.id == "com.bitwarden.Bitwarden.unlock" && subject.active) {
          return polkit.Result.AUTH_SELF;
        }
      });
    '';

    # Install the polkit policy from the bitwarden-desktop package
    # system-wide.
    environment.pathsToLink = [ "/share/polkit-1" ];
    environment.systemPackages = [
      pkgs.bitwarden-desktop
      pkgs.v4l-utils # `v4l2-ctl` for users running `face-doctor` or debugging
    ];
  };
}
