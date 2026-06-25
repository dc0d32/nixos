# Work around systemd 260 regression that breaks the per-user systemd
# manager (`user@<uid>.service`) under WSL.
#
# Symptom: on `wsl` startup Windows prints
#   "Failed to start the systemd user session for '<user>'. See
#    journalctl for more details."
# and the journal shows
#   user@<uid>.service: Failed to spawn executor: Device or resource busy
#
# Root cause: systemd upstream issue #41278 (fix targeted at v261).
# When the per-user manager is stopped, systemd 260's cgroup cleanup
# fails to tear the unit's cgroup down, leaving `cgroup.subtree_control`
# populated with domain controllers (`cpu memory pids`). The next start
# spawns the manager via `clone3(CLONE_INTO_CGROUP)` directly into that
# cgroup; cloning a process into a v2 cgroup that has domain controllers
# enabled violates the "no internal processes" rule, so the kernel
# returns EBUSY and the manager never comes up — taking the user's
# session D-Bus with it. WSL's interop layer polls
# `systemctl is-active user@<uid>.service` and surfaces the failure as
# the message above.
#
# This bites WSL specifically because the WSL boot/interop sequence
# churns the user manager (linger start + interop login) hard enough to
# hit the broken stop→start reuse path; bare-metal hosts rarely do.
#
# Fix: hook `OnFailure=` on every `user@<uid>.service` instance to a
# root oneshot that clears the stale `cgroup.subtree_control` and
# restarts the manager. `%i` carries the uid, so no host-specific uid
# wiring is needed. Once the manager starts into a clean cgroup it stays
# healthy for the rest of the session.
#
# Retire when: the host's systemd is >= 261 (or otherwise carries the
#   fix for https://github.com/systemd/systemd/issues/41278), at which
#   point the stop-time cgroup cleanup works and this recovery hook is
#   dead weight.
{ ... }:
{
  flake.modules.nixos.wsl-user-manager-fix = { pkgs, ... }:
    let
      recover = pkgs.writeShellApplication {
        name = "recover-user-manager";
        runtimeInputs = [ pkgs.systemd pkgs.coreutils ];
        text = ''
          uid="''${1:?usage: recover-user-manager <uid>}"
          unit="user@''${uid}.service"
          cg="/sys/fs/cgroup/user.slice/user-''${uid}.slice/''${unit}"
          ctl="''${cg}/cgroup.subtree_control"

          # Already healthy (e.g. a transient failure that self-resolved)
          # — nothing to do.
          if systemctl is-active --quiet "''${unit}"; then
            exit 0
          fi

          # Disable any domain controllers still enabled on the stale
          # cgroup so a fresh clone3(CLONE_INTO_CGROUP) into it succeeds.
          if [ -w "''${ctl}" ]; then
            read -ra controllers < "''${ctl}" || controllers=()
            if [ "''${#controllers[@]}" -gt 0 ]; then
              disable=""
              for c in "''${controllers[@]}"; do
                disable="''${disable} -''${c}"
              done
              printf '%s' "''${disable}" > "''${ctl}" || true
            fi
          fi

          systemctl reset-failed "''${unit}" || true
          systemctl restart "''${unit}"
        '';
      };
    in
    {
      # Drop-in (not a full unit) so we only append OnFailure= to the
      # upstream/NixOS-generated user@.service template.
      systemd.services."user@" = {
        overrideStrategy = "asDropin";
        unitConfig.OnFailure = "recover-user-manager@%i.service";
      };

      systemd.services."recover-user-manager@" = {
        description = "Recover user@%i after systemd #41278 cgroup EBUSY";
        # Cap the trigger→restart loop in the (proven-unlikely) case a
        # restart still fails, so we never spin forever.
        startLimitIntervalSec = 120;
        startLimitBurst = 5;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${recover}/bin/recover-user-manager %i";
        };
      };
    };
}
