# Biometrics — fingerprint reader (Synaptics Prometheus) baseline
# + optional face auth (howdy via IR camera) + PAM stack reordering
# + a Bitwarden polkit policy that pipes its unlock through the
# stack.
#
# Pattern A: hosts opt in by importing this module. Importing IS
# enabling fingerprint. Face unlock is a SEPARATE per-host opt-in
# via `flake-modules/face-unlock.nix` (it just sets
# `biometrics.face = true`), because howdy pulls a ~1.2 GiB
# closure (TensorFlow + dlib + face models) that not every
# biometric host wants.
#
# A `biometrics.enable` signal option (default false, set to true
# by this module's own config when imported) is published so other
# dendritic modules can adapt their UI without coupling to a
# host-level flag. (Currently no consumer reads it after the
# quickshell retreat — kept in place for future use; cheap.)
#
# Top-level options:
#   - biometrics.enable — read-only signal; true iff this module is
#     imported into the host. Set by mkDefault inside the module body
#     so other modules can inspect it without forcing a value.
#   - biometrics.cameraDevice — fallback /dev/video* path used at
#     boot before the autodetect oneshot picks the real IR sensor.
#     Optional; defaults to /dev/video2.
#
# NixOS-level option (declared inside the NixOS module so face-unlock
# can co-evaluate against it):
#   - biometrics.face — when true, install howdy + IR emitter
#     calibration + camera autodetect + howdy PAM rule. Default
#     false. Set to true by importing flake-modules/face-unlock.nix
#     alongside this module.
{ lib, config, ... }:
let
  cfg = config.biometrics;
in
{
  options.biometrics = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Read-only signal: true iff the biometrics module is imported on
        this host. Currently unused after the quickshell retreat; kept
        for future cross-module UI adaptation. Don't set this manually
        — import flake-modules/biometrics.nix to enable biometrics;
        the module sets this flag itself.
      '';
    };
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

  config = {
    # Importing this module IS enabling biometrics. Publish that fact as
    # a signal (no current consumer post-quickshell-retreat, but kept
    # for future cross-module wiring).
    biometrics.enable = lib.mkDefault true;

    flake.modules.nixos.biometrics = { lib, pkgs, config, ... }:
      let
        face = config.biometrics.face;
      in
      {
        options.biometrics.face = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            When true, install howdy + IR emitter calibration + camera
            autodetect + howdy PAM rule. Pulls ~1.2 GiB. Default false;
            set to true by importing flake-modules/face-unlock.nix
            alongside flake-modules/biometrics.nix.
          '';
        };

        config = {
          # ── Fingerprint reader (Synaptics Prometheus, 06cb:00fc) ─
          services.fprintd.enable = true;

          # ── Face auth (IR camera, howdy) — only on `face` hosts ──
          # services.howdy.enable auto-wires pam_howdy into the
          # standard PAM stacks at
          # security.pam.services.<name>.howdy.enable. IR emitter
          # must be configured once after first boot:
          #   sudo -E linux-enable-ir-emitter configure
          # device_path is overwritten at boot by
          # udev-howdy-camera.service below. The static value here
          # is just the initial / fallback in case autodetect finds
          # nothing.
          services.howdy = lib.mkIf face {
            enable = true;
            control = lib.mkDefault "sufficient";
            settings.video.device_path = lib.mkDefault cfg.cameraDevice;

            # Allow darker rooms. The default `dark_threshold = 60`
            # means a frame is rejected if more than 60% of its
            # pixels fall in the lowest 1/8 of the histogram. Raising
            # to 85 accepts dimmer rooms; false-accept risk is
            # unchanged because the actual face match still uses the
            # `certainty` threshold (3.5).
            # mkForce because upstream pins this to 60 at normal
            # priority, so mkDefault loses the merge.
            settings.video.dark_threshold = lib.mkForce 85;
          };

          services.linux-enable-ir-emitter = lib.mkIf face {
            enable = true;
            # Strip the /dev/ prefix; the option takes a bare device name.
            device = lib.removePrefix "/dev/" cfg.cameraDevice;
          };

          # ── PAM auth ordering ───────────────────────────────────
          #
          # The default NixOS biometric stack runs `auth sufficient
          # pam_howdy.so` and `auth sufficient pam_fprintd.so`
          # BEFORE `auth sufficient pam_unix.so`. That means PAM
          # blocks on the fingerprint sensor (a synchronous read)
          # for several seconds even when the user has already typed
          # a password — the password line is unreachable until
          # fprintd returns.
          #
          # We override the `order` of howdy and fprintd so they
          # slot deliberately around `pam_unix`. There are two
          # policies, applied per-service:
          #
          #   "face-first"     (sudo, login, ly):
          #       howdy → pam_unix → fprintd → deny
          #     The IR camera is fast (~1s); leading with face gives
          #     a Windows Hello-style "look at the laptop and you're
          #     in" experience. Falls through to a typed password if
          #     the camera shot doesn't match, then to fingerprint
          #     as a slower last-resort biometric.
          #
          #   "password-first" (bitwarden):
          #       pam_unix → howdy → fprintd → deny
          #     Vault unlock is a deliberate gesture; we want the
          #     user to type a password rather than glance and have
          #     the vault open. Biometrics remain available as a
          #     fallback.
          #
          # On `face=false` hosts, the howdy.order assignments below
          # are skipped (mkIf face) — only fprintd's order matters
          # and the stack collapses to pam_unix → fprintd → deny.
          #
          # Important caveats for "face-first" on login/ly:
          # `pam_unix-early` (optional, order 11700) and
          # `pam_gnome_keyring` (optional, order 12200) still run
          # before howdy *only if howdy is ordered above them*. On
          # sudo there is no keyring, so howdy can sit at the very
          # top. On login/ly we slot howdy at 12500 — above the
          # keyring (12200), below the *sufficient* pam_unix
          # (12900) — so:
          #   1. unix-early(11700) tries to capture an AUTHTOK.
          #   2. gnome_keyring(12200) consumes the AUTHTOK if present.
          #   3. howdy(12500) attempts face match; on success, short-circuits.
          #   4. unix(12900) prompts for password as fallback.
          #   5. fprintd(13000) prompts for finger as final fallback.
          #   6. deny(13100) — required-last sentinel so a complete
          #      fall-through yields a clean failure rather than
          #      landing on the next module.
          #
          # KEYRING CAVEAT: when face-login wins on login/ly, no
          # password is ever typed, so AUTHTOK is empty, and
          # pam_gnome_keyring cannot unlock the login keyring. The
          # user will get a separate "unlock keyring" prompt later
          # when an app needs it. To get the keyring auto-unlocked,
          # type the password into ly/login instead of using face.
          #
          # The pam_deny rule MUST stay last. Different services
          # have different default deny orders (login/ly: 13700;
          # sudo/bitwarden: 12500); we relocate deny to 13100
          # explicitly so we don't get stranded behind it on sudo /
          # bitwarden. Don't go below 13000 or fprintd becomes
          # unreachable.
          security.pam.services =
            let
              mkReorder = { howdyOrder }: {
                rules.auth = {
                  fprintd.order = 13000;
                  # Force deny last so we don't get stranded behind
                  # it on services whose default deny is at 12500
                  # (sudo, bitwarden).
                  deny.order = 13100;
                } // lib.optionalAttrs face {
                  howdy.order = howdyOrder;
                };
              };
              # Face-first for sudo: howdy at the very top (below
              # account 11000 range, above auth pam_unix 11700).
              reorderFaceFirstSudo = mkReorder { howdyOrder = 11500; };
              # Face-first for login/ly: leave room for
              # unix-early(11700) and gnome_keyring(12200).
              reorderFaceFirstLogin = mkReorder { howdyOrder = 12500; };
              # Password-first for bitwarden.
              reorderPasswordFirst = mkReorder { howdyOrder = 12950; };
            in
            {
              sudo = reorderFaceFirstSudo // { fprintAuth = lib.mkDefault true; };
              login = reorderFaceFirstLogin // { fprintAuth = lib.mkDefault true; };
              ly = reorderFaceFirstLogin // { fprintAuth = lib.mkDefault true; };

              # Bitwarden biometric unlock: polkit calls this PAM
              # service to verify the user before releasing the
              # vault key. Password-first; biometrics as fallback.
              # Retire if bitwarden-desktop ever ships its own PAM
              # service file.
              bitwarden = reorderPasswordFirst // { fprintAuth = lib.mkDefault true; };
            };

          # ── Camera autodetect (face-only) ───────────────────────
          # USB enumeration order is not stable: the Chicony IR
          # camera may land on /dev/video0, /dev/video2, /dev/video4,
          # etc. depending on boot timing. Hardcoding device_path
          # breaks face unlock whenever the kernel renumbers the
          # v4l2 nodes.
          #
          # Workaround: at boot (after systemd-udev-settle) walk
          # /dev/video* and pick the first node that v4l2-ctl
          # reports as having the V4L2_CAP_META_CAPTURE | infrared
          # capability flag, falling back to device-name match for
          # "infrared" / "IR". Rewrite /etc/howdy/config.ini
          # in-place so howdy sees the right device on its next
          # invocation.
          #
          # Retire when nixpkgs services.howdy gets a
          # `device.autodetect = true` option, or when the kernel /
          # firmware exposes a stable /dev/v4l/by-id/ symlink for
          # the IR camera (currently unreliable on this hardware).
          systemd.services.howdy-camera-autodetect = lib.mkIf face {
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
                  info=$(v4l2-ctl --device "$dev" --info 2>/dev/null || true)
                  name=$(printf '%s' "$info" | awk -F': ' '/Card type/ {print $2; exit}')
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

              if [ -L "$cfg" ] || [ -f "$cfg" ]; then
                tmp=$(mktemp)
                sed "s|^device_path = .*|device_path = $detected|" "$cfg" > "$tmp"
                rm -f "$cfg"
                mv "$tmp" "$cfg"
                chmod 0644 "$cfg"
              fi
            '';
          };

          # ── Bitwarden polkit policy ─────────────────────────────
          # bitwarden-desktop is installed via home-manager, so its
          # share/polkit-1 directory isn't picked up by the system
          # polkit aggregation. Install the policy at the NixOS
          # level so polkit can authorize biometric unlock.
          # Retire when bitwarden-desktop moves to environment.
          # systemPackages or NixOS polkit starts scanning HM
          # packages.
          security.polkit.extraConfig = ''
            polkit.addRule(function (action, subject) {
              if (action.id == "com.bitwarden.Bitwarden.unlock" && subject.active) {
                return polkit.Result.AUTH_SELF;
              }
            });
          '';

          # Install the polkit policy from the bitwarden-desktop
          # package system-wide.
          environment.pathsToLink = [ "/share/polkit-1" ];
          environment.systemPackages = [
            pkgs.bitwarden-desktop
            pkgs.v4l-utils # `v4l2-ctl` for users running `face-doctor` or debugging

            # Interactive enrollment helper. Wraps fprintd-enroll +
            # (when face is enabled) linux-enable-ir-emitter
            # configure + howdy add into one discoverable command.
            # Subcommands: fingerprint | face | all (default) |
            # verify. On `face=false` hosts the face / all / verify
            # subcommands gracefully report that face unlock isn't
            # installed; fingerprint always works.
            # Retire when: nixpkgs ships an equivalent enrollment
            # TUI, or the howdy/fprintd setup becomes a one-liner
            # upstream.
            (pkgs.writeShellApplication {
              name = "biometrics-enroll";
              runtimeInputs = [
                pkgs.fprintd
                pkgs.coreutils
                pkgs.gnused
                pkgs.gawk
              ] ++ lib.optionals face [
                pkgs.howdy
                pkgs.linux-enable-ir-emitter
              ];
              bashOptions = [ "errexit" "nounset" "pipefail" ];
              text = builtins.readFile ../scripts/biometrics-enroll.sh;
            })
          ];
        };
      };
  };
}
