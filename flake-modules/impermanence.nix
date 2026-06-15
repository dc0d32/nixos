# impermanence — wipe the root subvol back to an empty snapshot on
# every boot. Anything that should survive a reboot lives under
# `/persist` and is bind-mounted back into its original location by
# the upstream impermanence module. The list covers BOTH system state
# (under /var, /etc, /root) AND per-user state (under each normal
# user's home — browsers, bitwarden, gnupg, kicad, freecad, etc.).
# Everything else is ephemeral — Nix-managed config in /etc, /var
# ephemera, and whatever the user accidentally drops in $HOME between
# boots gets vaporised.
#
# Why a single NixOS-side module rather than NixOS-side + HM-side:
#   The upstream impermanence HM module is deprecated for standalone
#   HM use (it requires home-manager to be wired into NixOS as a
#   module, which we deliberately do not do — see CLAUDE.md). The
#   NixOS module exposes `environment.persistence."<x>".users.<login>`
#   which gives us exactly the same per-user bind-mount machinery
#   without that coupling. So all of impermanence — system + user —
#   lives in this one file.
#
# Why a fresh install loses its mind without this:
#   On a long-lived NixOS host, /var and $HOME accumulate state that
#   nothing in the flake describes (browser profiles, ad-hoc dotfiles,
#   FreeCAD prefs, machine-id, NetworkManager keyrings, …). After
#   six months you can't tell what's "real config" vs "I once ran
#   command X and it left a turd". Reinstalling such a host means
#   re-deriving that pile by hand — exactly the toil this whole
#   exercise exists to eliminate.
#
#   With impermanence, every irreducible piece of state is explicitly
#   listed below. The next time we reinstall, the new install
#   boots into a blank root, and the backup-restore wrapper from
#   flake-modules/backup.nix puts /persist back exactly as it was —
#   which the impermanence bind-mounts then re-expose at /var/...,
#   /home/<user>/..., etc. Anything NOT on the persistence list is,
#   by definition, "stuff we didn't care enough about to declare" and
#   is gone.
#
# Mechanics (btrfs root-rollback in initrd):
#   At install time, the disko script creates an empty RO snapshot of
#   the freshly-created `root` subvol named `root-blank` at the btrfs
#   top level. On every boot, before the rootfs mount, an initrd
#   systemd service mounts the top-level (subvolid=5) at /btrfs_tmp,
#   archives the live `root` subvol under .../old_roots/<timestamp>/,
#   then restores a fresh writable copy of `root` from the
#   `root-blank` RO snapshot. The kernel then mounts subvol=root at /
#   as usual. /persist + /nix + /home (separate subvols) survive
#   untouched because nothing deletes them.
#
# Why btrfs subvol rollback (not tmpfs root):
#   - tmpfs root caps available memory and forces every store path
#     resolution onto RAM during boot.
#   - subvol rollback keeps the btrfs layout disko already manages —
#     no new filesystem in the mount table.
#   - "Wipe the world on reboot" is the same posture either way; only
#     the storage mechanism differs.
#
# Cross-module signal:
#   options.impermanence.enable (declared INSIDE the NixOS module,
#   so it's per-NixOS-config rather than a flake-parts singleton) is
#   set to true by this module's own config block. Other NixOS modules
#   that care about impermanence (e.g. flake-modules/backup.nix to
#   decide whether to include /persist as a backup source) declare the
#   SAME option (with the same default = false). NixOS module merge
#   makes it true wherever this module is imported, false elsewhere.
#
# Pattern A: importing IS enabling. Hosts that want impermanence add
#   config.flake.modules.nixos.impermanence
# to their bridge `imports = [ … ]`. The disko factory creates the
# `root-blank` snapshot AND the `persist` subvol unconditionally
# (both are tiny and harmless on hosts that don't currently use
# impermanence), so importing this module on an already-disko-installed
# host just works after a `sudo nixos-rebuild boot && reboot`.
#
# Retire when:
#   - Every host in this repo runs impermanence (the option gate
#     becomes redundant), AND
#   - NixOS upstream ships a first-class root-rollback option that
#     supersedes the hand-rolled initrd script below.
{ inputs, ... }:
{
  flake.modules.nixos.impermanence = { lib, config, pkgs, ... }:
    let
      cfg = config.impermanence;
      normalUsers = lib.filterAttrs (_: u: u.isNormalUser) config.users.users;
    in
    {
      imports = [ inputs.impermanence.nixosModules.impermanence ];

      options.impermanence = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Cross-module signal: true on hosts that import
            flake.modules.nixos.impermanence, false elsewhere. Read by
            flake.modules.nixos.backup to decide whether /persist is
            one of the backup sources. Don't set this manually — import
            this module to enable impermanence; the module sets the
            signal itself.
          '';
        };

        persistRoot = lib.mkOption {
          type = lib.types.str;
          default = "/persist";
          description = ''
            Mountpoint of the persistent btrfs subvol. Defaults to
            /persist; only override if a host needs to relocate it
            (very rarely useful — the path is referenced by
            environment.persistence."<x>" and by the backup module
            with the same default).
          '';
        };

        userDirectories = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          description = ''
            Directories inside every normal user's home that are
            bind-mounted from <persistRoot>/home/<login>/. Anything
            listed here survives root rollback; anything NOT listed
            (and not Nix-managed via HM) is gone after reboot.

            Curated for the desktop persona this flake targets: shell
            history, browsers, gnupg/ssh, bitwarden, freecad/kicad,
            gh cli, the operator's working trees (~/nixos, ~/src,
            ~/Documents, ~/Downloads, ~/Pictures). Per-host extras
            extend in the host bridge:
              environment.persistence."/persist".users.<login>.directories
                = [ "extra/dir" ];

            Why NixOS-side rather than HM-side: the HM impermanence
            module is deprecated for standalone HM and requires the
            HM-NixOS-module integration we deliberately avoid (see
            CLAUDE.md "Do not wire home-manager into NixOS as a
            module"). The NixOS impermanence module exposes the same
            functionality via `environment.persistence.<x>.users.<login>`
            without that coupling.
          '';
          default = [
            ".local/share/zsh"
            ".local/share/fish"
            ".local/share/atuin"
            ".local/state/nix"
            ".local/state/home-manager"
            ".ssh"
            ".gnupg"
            ".mozilla"
            ".config/google-chrome"
            ".config/chromium"
            ".config/BraveSoftware"
            ".config/Bitwarden"
            ".config/Bitwarden CLI"
            ".config/FreeCAD"
            ".local/share/FreeCAD"
            ".config/kicad"
            ".local/share/kicad"
            ".config/gh"
            "nixos"
            "src"
            "code"
            "Documents"
            "Downloads"
            "Pictures"
            ".local/share/Trash"
            ".config/systemd"
            ".local/share/systemd"
            # cliphist clipboard history DB. flake.modules.homeManager
            # .desktop-shell installs cliphist + a pair of systemd-user
            # watchers; without this entry the history is wiped every
            # boot and Mod+Shift+C lands on an empty fuzzel picker.
            ".local/share/cliphist"
            # direnv allow-list + cached envs. flake.modules.homeManager
            # .direnv enables direnv with nix-direnv; without this entry
            # every `cd` into a project re-prompts `direnv allow` and
            # re-evaluates the flake env from scratch.
            ".local/share/direnv"
            # gnome-keyring / libsecret store. Many GUI apps (browsers,
            # bitwarden CLI, gh, vscode, JetBrains, signal, slack)
            # default to libsecret for credential storage. Listing
            # speculatively is harmless on hosts that don't install
            # those apps.
            ".local/share/keyrings"
            # dconf — GTK app prefs (file manager state, gtk dark mode,
            # cursor blink, per-app remembered window sizes). Browsers
            # and GTK apps key off this; losing it resets a long tail
            # of small UX state on every boot.
            ".config/dconf"
          ];
        };

        userFiles = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          description = ''
            Files (rather than whole dirs) bind-mounted per user.
            Use sparingly — bind-mounting individual files is
            fragile; the impermanence module falls back to symlinks.
          '';
          default = [
            ".zsh_history"
          ];
        };
      };

      config = {
        # Publish the signal. Importing IS enabling.
        impermanence.enable = lib.mkDefault true;

        # ── btrfs root-rollback in initrd ──────────────────────────
        # systemd-stage-1 initrd: required for the systemd.services
        # entry below to fire before sysroot mount. The legacy
        # script-stage-1 initrd can't run a systemd unit at all.
        boot.initrd.systemd.enable = lib.mkDefault true;

        # btrfs-progs in initrd so the rollback script can mount the
        # top-level subvol and run `btrfs subvolume snapshot/delete`.
        boot.initrd.systemd.initrdBin = [ pkgs.btrfs-progs ];

        boot.initrd.systemd.services.rollback = {
          description = "Rollback btrfs root subvol to root-blank";
          wantedBy = [ "initrd.target" ];
          # Must finish BEFORE sysroot is mounted from subvol=root.
          # systemd-initrd uses sysroot.mount for that. We don't list
          # the device unit explicitly because the unit name encodes
          # systemd-escape-mangled partlabels which vary by host /
          # encryption / disk; sysroot.mount has its own dependency
          # graph on the right device and we just need to fire before
          # it, regardless of how it gets unblocked.
          before = [ "sysroot.mount" ];
          unitConfig.DefaultDependencies = "no";
          serviceConfig.Type = "oneshot";
          script = ''
            set -euo pipefail
            mkdir -p /btrfs_tmp

            # Mount the btrfs top-level (subvolid=5) so we can see +
            # edit the subvol tree. Try the LUKS-opened mapper first
            # (encrypted hosts), then the partlabel (plaintext hosts).
            # Whichever exists is what disko produced.
            if [ -b /dev/mapper/cryptroot ]; then
              mount -t btrfs -o subvol=/ /dev/mapper/cryptroot /btrfs_tmp
            else
              mount -t btrfs -o subvol=/ \
                /dev/disk/by-partlabel/disk-main-nixos /btrfs_tmp
            fi

            # Archive whatever is currently in `root` under
            # /btrfs_tmp/old_roots/<timestamp>/ so a wedged debugging
            # session has a chance to recover anything the operator
            # forgot to declare in environment.persistence. Cleaned up
            # below if it's older than 30 days.
            if [ -e /btrfs_tmp/root ]; then
              mkdir -p /btrfs_tmp/old_roots
              timestamp=$(date --date="@$(stat -c %Y /btrfs_tmp/root)" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null || echo unknown)
              mv /btrfs_tmp/root "/btrfs_tmp/old_roots/$timestamp" || \
                btrfs subvolume delete /btrfs_tmp/root || true
            fi

            # Prune old archives (>30 days) so the disk doesn't fill
            # up with forgotten rollbacks. -mtime tolerates clock skew
            # on a host that hasn't synced NTP yet (first boot).
            if [ -d /btrfs_tmp/old_roots ]; then
              for old in $(find /btrfs_tmp/old_roots/ -maxdepth 1 -mindepth 1 -mtime +30 2>/dev/null); do
                btrfs subvolume delete "$old" || true
              done
            fi

            # Restore a fresh writable copy of `root` from the RO
            # `root-blank` snapshot the disko factory created at
            # install time. If root-blank is missing (host is not yet
            # migrated to a disko factory that creates it), abort
            # cleanly and let the existing root mount through — the
            # operator can run the migration script and try again.
            if [ ! -e /btrfs_tmp/root-blank ]; then
              echo "rollback: /btrfs_tmp/root-blank missing; restoring archived root in place" >&2
              if [ -d /btrfs_tmp/old_roots ]; then
                last=$(ls -1t /btrfs_tmp/old_roots | head -1 || true)
                if [ -n "$last" ]; then
                  btrfs subvolume snapshot \
                    "/btrfs_tmp/old_roots/$last" /btrfs_tmp/root
                fi
              fi
            else
              btrfs subvolume snapshot /btrfs_tmp/root-blank /btrfs_tmp/root
            fi

            umount /btrfs_tmp
          '';
        };

        # ── /persist must be mounted before /var (and most of /) is
        # accessed by impermanence's bind-mount machinery ───────────
        # Disko declares the `persist` subvol at mountpoint
        # persistRoot. Mark it neededForBoot so it's mounted in
        # initrd, before systemd-tmpfiles or any service that
        # touches the directories impermanence binds back.
        #
        # Set unconditionally — checking `config.fileSystems` here
        # creates infinite recursion (this block IS a definition of
        # config.fileSystems). If the host's disko layout doesn't
        # actually produce /persist, the assertion below + NixOS'
        # own fileSystems validator catches it.
        #
        # /home is also needed early: impermanence assertion requires
        # every filesystem hosting a persistence target to be
        # neededForBoot, and `users.<login>` targets land under /home.
        fileSystems.${cfg.persistRoot}.neededForBoot = lib.mkDefault true;
        fileSystems."/home".neededForBoot = lib.mkDefault true;

        # ── Default persistence list ───────────────────────────────
        # Anything irreducible at the SYSTEM level. Hosts can extend
        # this list in their bridge with
        #   environment.persistence."/persist".directories = [ … ];
        # or
        #   environment.persistence."/persist".files = [ … ];
        # but the defaults below cover the common 90%.
        environment.persistence.${cfg.persistRoot} = {
          hideMounts = true;
          directories = [
            # System logs — survives reboots so journalctl history is
            # useful across crashes.
            "/var/log"
            # Bluetooth pairings (PINs, link keys, profile DBs).
            "/var/lib/bluetooth"
            # systemd state (resolved cache, timesync drift, rfkill,
            # random seed).
            "/var/lib/systemd"
            # NixOS internal state — `nixos-rebuild` writes here.
            "/var/lib/nixos"
            # NetworkManager: declared connections + system-connection
            # secrets. Losing this means re-pairing every WiFi network.
            "/etc/NetworkManager/system-connections"
            # NetworkManager runtime state — DHCP leases, last-known
            # state, connection timestamps. Without this, every boot
            # NM treats every known network as never-seen-before,
            # which delays reconnect and re-runs DHCP from scratch.
            "/var/lib/NetworkManager"
            # AccountsService — user metadata consumed by ly + future
            # greeters (avatar paths, last-session). Cheap to list.
            "/var/lib/AccountsService"
            # fwupd firmware DB cache. flake.modules.nixos.power
            # enables fwupd; without this, every boot re-downloads
            # the LVFS catalog before the first `fwupdmgr` call.
            "/var/lib/fwupd"
            # UPower — battery history (informational; tiny).
            "/var/lib/upower"
            # fprintd / iwd state if the host has biometrics or iwd.
            # Listing speculatively is harmless — impermanence creates
            # them empty as needed.
            "/var/lib/fprint"
            "/var/lib/iwd"
            # libvirt / docker / colord / power-profiles persistence —
            # cheap to list speculatively.
            "/var/lib/docker"
            "/var/lib/libvirt"
            "/var/lib/colord"
            "/var/lib/power-profiles-daemon"
            # tpm2-tss "owner" persistent objects index (TPM2 LUKS
            # unlock + future signing keys).
            "/var/lib/tpm2-tss"
            # sudo lecture cache — without this, sudo re-displays its
            # first-use lecture on every boot.
            "/var/db/sudo/lectured"
            # root's home (for whatever a recovery sudo session leaves
            # behind — bash history, ad-hoc ssh keys).
            "/root"
            # Backup credentials. Owned by flake.modules.nixos.backup;
            # listed here so importing only impermanence (without
            # backup) still survives the backup module's eventual
            # addition without an extra persist entry.
            "/etc/restic"
            "/etc/ssh-restic"
          ];
          files = [
            # machine-id: many services key host identity off this.
            # Losing it churns systemd journals + breaks systemd-id128.
            "/etc/machine-id"
            # RTC drift calibration written by hwclock --adjust. Tiny
            # text file; losing it means the kernel re-learns RTC
            # drift on every boot from scratch, which is harmless but
            # wastes the calibration the previous boot did for us.
            "/etc/adjtime"
            # SSH host keys: changing these on every boot is a recipe
            # for SSH client warnings and Tailscale-style identity
            # churn. Pin them.
            "/etc/ssh/ssh_host_ed25519_key"
            "/etc/ssh/ssh_host_ed25519_key.pub"
            "/etc/ssh/ssh_host_rsa_key"
            "/etc/ssh/ssh_host_rsa_key.pub"
            # User/group state. With mutableUsers = true (the NixOS
            # default), `passwd` writes to /etc/shadow at runtime; if
            # we don't persist it, every reboot wipes the user's
            # password and the activation script re-applies whatever
            # `initialPassword` is in the host bridge. That includes
            # the swaylock-rejects-correct-password failure mode —
            # the password you set yesterday is gone. Persisting the
            # whole shadow/passwd/group set is the canonical
            # impermanence workaround. /etc/subuid + /etc/subgid are
            # cheap to list and matter for podman/userns rootless
            # containers.
            "/etc/passwd"
            "/etc/shadow"
            "/etc/group"
            "/etc/gshadow"
            "/etc/subuid"
            "/etc/subgid"
          ];

          # Per-user persistence — impermanence's NixOS module supports
          # users.<login>.{directories,files} natively. Paths are
          # automatically prefixed with the user's home dir. Storage
          # ends up under <persistRoot>/home/<login>/<path>.
          users = lib.mapAttrs
            (_: _: {
              directories = cfg.userDirectories;
              files = cfg.userFiles;
            })
            normalUsers;
        };

        # impermanence binds /var/lib/nixos from /persist. If /persist
        # is missing the host won't allocate uids correctly on second
        # boot. This assertion is documentation, not enforcement.
        assertions = [{
          assertion = config.fileSystems ? ${cfg.persistRoot};
          message = ''
            impermanence is imported but no fileSystems."${cfg.persistRoot}"
            is declared. The host's disko layout must include a
            persist subvol mounted at ${cfg.persistRoot}. See
            flake-modules/disko.nix (bare-metal factory) — the factory
            now creates the persist subvol unconditionally.
          '';
        }];
      };
    };
}
