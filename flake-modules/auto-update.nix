# auto-update — the opportunistic driver that decides *when* this host
# pulls `origin/main` and re-activates itself.
#
# Why this module exists (history): the first cut of auto-deploy was two
# unrelated calendar timers — `nixos-upgrade.timer` at 04:40 and
# `hm-auto-upgrade.timer` at 05:30. Three things went wrong with that,
# all of them observed in the field:
#
#   1. **The machines aren't awake at 04:40.** Laptops are suspended or
#      off. `Persistent=true` catches "the host was powered down", but
#      it only ever grants ONE make-up run, fired the instant the lid
#      opens — the worst possible moment, because WiFi hasn't
#      associated yet and the machine is on battery. It fails, and the
#      next opportunity is 24 hours later. In practice hosts drifted
#      for weeks.
#   2. **No ordering.** On a catch-up boot both timers elapse at once,
#      so `home-manager switch` raced `nixos-rebuild switch` instead of
#      running after it.
#   3. **No power policy.** A 500 MB closure download + a full
#      activation on battery, on a laptop the user just opened, is
#      exactly the wrong time.
#
# The replacement is a *polling* driver rather than a calendar one:
#
#   `auto-update.timer`  fires ~hourly whenever the machine happens to
#                        be awake (OnBootSec + OnUnitActiveSec, both
#                        monotonic, so suspend time counts and a wake
#                        after a long sleep fires promptly).
#   `auto-update.service` is a *sequencer*. Its `ExecCondition=` decides
#                        whether now is a good moment; if not the unit
#                        is skipped (systemd logs "condition failed",
#                        the unit does NOT enter `failed`), and we try
#                        again next hour. If it is a good moment, the
#                        `ExecStart=` runs the real work units in a
#                        fixed order.
#
# The gate ("is now a good moment?") is five checks, in this order:
#
#   a. **Minimum interval** (default 6h since the last attempt). This is
#      the rate limit, and it is load-bearing: the quiet window is 7h
#      wide and the timer polls hourly, so without it a host that is
#      awake overnight runs the whole sequence ~7 times a night — and a
#      host with a persistently failing step never advances its
#      `last-success` stamp, so it would run a full `nixos-rebuild
#      switch --refresh` every hour, forever, with no backoff.
#   b. **Quiet window** (default 02:00–09:00 local). Inside it, go. The
#      window is generous on the morning side precisely because that's
#      when a suspended laptop actually gets opened.
#   c. **Staleness fallback** (default 24h). Outside the window, go
#      anyway if the last *successful* full run was more than 24h ago.
#      This is what keeps a machine that is only ever used 09:00–23:00
#      from never updating. Without it the quiet window is a trap.
#   d. **Wall power.** `ac-check` from flake-modules/power-gate.nix.
#      On battery → skip. Undeterminable → proceed (an undetectable
#      machine that never updates is worse than one that occasionally
#      updates on battery). WSL is covered: power-gate asks Windows
#      over interop, so a WSL distro on a laptop running off battery
#      also holds off.
#   e. **Reachability.** Short bounded poll of the flake host. No
#      network → skip; don't burn a run on a `nixos-rebuild` that is
#      going to fail its fetch.
#
# Deliberately NOT done here:
#   * **No `WakeSystem=true`.** A laptop in a bag stays asleep. Waking
#     a machine to update it is how you cook a laptop in a backpack.
#   * **No reboots.** See flake-modules/auto-upgrade.nix.
#   * **No lock bumping.** The `flake.lock` committed in the repo is
#     what every host deploys; hosts never resolve inputs themselves.
#
# Prompt reaction to plugging in: a udev rule pokes the sequencer when
# a Mains supply goes online, so "plug the laptop in at 08:50" starts
# an update within seconds instead of at the top of the next hour. The
# gate still runs, so the poke is harmless outside the window, and the
# minimum-interval check means unplug/replug cycling can't turn into a
# rebuild storm.
#
# Observability (the thing the calendar design lacked entirely):
#   auto-update-status      what happened last run, per step, and when
#   auto-update-now         force a run now, ignoring window/AC/staleness
#   journalctl -u auto-update.service
#
# Which work units run is not hardcoded here: each feature module
# registers itself by appending to `autoUpdate.steps` with an explicit
# `lib.mkOrder`, so the sequence is
#   100  nixos-auto-upgrade.service   (flake-modules/auto-upgrade.nix)
#   200  hm-auto-upgrade.service      (flake-modules/hm-auto-upgrade.nix)
# and a host that imports only one of them still gets a working driver.
# (The order is explicit rather than relying on module import order,
# which is not something to bet a `home-manager switch` on.)
#
# This module declares the `autoUpdate.*` options the two feature
# modules read, so it must be imported alongside them — which is why all
# three live in one bundle rather than being opt-in individually.
#
# Pattern A (importing IS enabling): hosts get this via
# `config.flake.lib.bundles.nixos.auto-deploy`.
#
# Retire when: push-based deploys (deploy-rs / CI `nixos-rebuild
#   --target-host`) replace pull-based auto-deploy, OR systemd grows a
#   first-class `ConditionACPower=` + "run when idle and on power"
#   scheduler that subsumes the gate.
{ config, ... }:
let
  outerLib = config.flake.lib;
in
{
  flake.modules.nixos.auto-update = { config, lib, pkgs, ... }:
    let
      cfg = config.autoUpdate;

      acCheck = outerLib.mkAcCheck { inherit pkgs; };

      stateDir = "/var/lib/auto-update";

      # Work units, in the order they must run. Contributed by the
      # feature modules via `lib.mkOrder`; see the module header.
      #
      # NB: this deliberately does NOT sniff `config.systemd.services`
      # for the unit names. Gating this module's own
      # `systemd.services.auto-update` definition on the *names* of
      # `config.systemd.services` is an infinite recursion — computing
      # the name set requires evaluating the very `mkIf` condition being
      # computed.
      steps = cfg.steps;
      bestEffortSteps = cfg.bestEffortSteps;
      allSteps = bestEffortSteps ++ steps;

      # Host part of the flake URI, used for the reachability probe.
      # "github:dc0d32/nixos" -> "github.com". Anything we can't parse
      # falls back to github.com, which is where this repo lives.
      probeHost =
        if lib.hasPrefix "github:" cfg.flake then "github.com"
        else if lib.hasPrefix "gitlab:" cfg.flake then "gitlab.com"
        else "github.com";

      # "02:30" -> "150". toIntBase10, not toInt: toInt throws on
      # leading zeros ("ambiguity between octal and zero padded"), and
      # every time before 10:00 is zero padded.
      hhmmToMinutes = s:
        let parts = lib.splitString ":" s;
        in toString (
          60 * (lib.toIntBase10 (lib.elemAt parts 0))
          + (lib.toIntBase10 (lib.elemAt parts 1))
        );

      gateScript = pkgs.writeShellApplication {
        name = "auto-update-gate";
        runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.bash acCheck ];
        text = ''
          # ExecCondition semantics: exit 0 => run, exit 1..254 => skip
          # quietly (unit is NOT marked failed), >=255 => hard failure.
          # Every "not now" path below therefore exits 1.
          state_dir=${stateDir}
          stale_seconds=${toString (cfg.staleAfterHours * 3600)}
          min_interval_seconds=${toString (cfg.minIntervalHours * 3600)}
          mkdir -p "$state_dir"

          read_stamp() {
            local f="$state_dir/$1" v=0
            if [ -r "$f" ]; then
              v=$(cat "$f" 2>/dev/null || echo 0)
            fi
            case "$v" in
              *[!0-9]*) v=0 ;;
              "") v=0 ;;
              *) ;;
            esac
            printf '%s' "$v"
          }

          # Stamping the *attempt* (here, in the gate) rather than the
          # completion (in the sequencer) is deliberate: a run killed by
          # TimeoutStartSec or by a shutdown mid-switch must still count
          # against the throttle, or a host that can never finish a run
          # retries forever at the poll interval.
          proceed() {
            date +%s > "$state_dir/last-attempt"
            echo "gate: all conditions met"
            exit 0
          }

          if [ "''${AUTO_UPDATE_FORCE:-0}" = "1" ]; then
            echo "gate: AUTO_UPDATE_FORCE=1, bypassing all checks"
            proceed
          fi

          # ── (a) minimum interval since the last attempt ────────────
          # Without this the gate has no rate limit at all: the quiet
          # window is 7h wide and the timer polls hourly, so any host
          # awake overnight would run the whole sequence ~7 times a
          # night — and a host with a persistently failing step (a user
          # whose HM activation collides with a stale dotfile, say)
          # would never advance `last-success` and so would run the full
          # `nixos-rebuild switch --refresh` every hour, forever.
          last_attempt=$(read_stamp last-attempt)
          attempt_age=$(( $(date +%s) - last_attempt ))
          if [ "$attempt_age" -lt "$min_interval_seconds" ]; then
            echo "gate: last attempt was ''${attempt_age}s ago (< ''${min_interval_seconds}s), skipping"
            exit 1
          fi

          # ── (b) quiet window / (c) staleness ───────────────────────
          now_min=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
          ${lib.optionalString (cfg.quietWindow != null) ''
            win_start=${hhmmToMinutes cfg.quietWindow.start}
            win_end=${hhmmToMinutes cfg.quietWindow.end}
            in_window=0
            if [ "$win_start" -le "$win_end" ]; then
              if [ "$now_min" -ge "$win_start" ] && [ "$now_min" -lt "$win_end" ]; then
                in_window=1
              fi
            else
              # window wraps midnight (e.g. 22:00 -> 06:00)
              if [ "$now_min" -ge "$win_start" ] || [ "$now_min" -lt "$win_end" ]; then
                in_window=1
              fi
            fi
          ''}
          ${lib.optionalString (cfg.quietWindow == null) "in_window=1"}

          last_success=$(read_stamp last-success)
          age=$(( $(date +%s) - last_success ))

          if [ "$in_window" -eq 1 ]; then
            echo "gate: inside quiet window, proceeding"
          elif [ "$age" -ge "$stale_seconds" ]; then
            echo "gate: outside quiet window but last success was ''${age}s ago (>= ''${stale_seconds}s), proceeding"
          else
            echo "gate: outside quiet window and last success only ''${age}s ago, skipping"
            exit 1
          fi

          # ── (d) wall power ─────────────────────────────────────────
          ${lib.optionalString cfg.requireAC ''
            set +e
            ac-check --verbose
            ac_rc=$?
            set -e
            case "$ac_rc" in
              0) echo "gate: on wall power" ;;
              1) echo "gate: on battery, skipping"; exit 1 ;;
              *) echo "gate: power state undeterminable, proceeding anyway" ;;
            esac
          ''}

          # ── (e) reachability ───────────────────────────────────────
          # A systemd service inherits none of the session variables
          # NixOS sets for interactive shells, so curl has no CA bundle
          # unless we hand it one — without this the probe fails with
          # "unable to get local issuer certificate" on every poll and
          # the host never updates. Fall back to a plain TCP connect if
          # the bundle is missing for any reason, so a CA problem can
          # never be the thing that wedges the updater.
          probe() {
            if [ -r /etc/ssl/certs/ca-certificates.crt ]; then
              SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
              NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
                curl --silent --head --fail --max-time 10 \
                  "https://${probeHost}" >/dev/null 2>&1
            else
              timeout 10 bash -c 'exec 3<>/dev/tcp/${probeHost}/443' 2>/dev/null
            fi
          }

          deadline=$(( $(date +%s) + ${toString cfg.networkWaitSeconds} ))
          reachable=0
          while :; do
            if probe; then
              reachable=1
              break
            fi
            if [ "$(date +%s)" -ge "$deadline" ]; then
              break
            fi
            sleep 5
          done
          if [ "$reachable" -ne 1 ]; then
            echo "gate: ${probeHost} unreachable after ${toString cfg.networkWaitSeconds}s, skipping"
            exit 1
          fi
          echo "gate: ${probeHost} reachable"

          proceed
        '';
      };

      runScript = pkgs.writeShellApplication {
        name = "auto-update-run";
        runtimeInputs = [ pkgs.coreutils config.systemd.package ];
        text = ''
          state_dir=${stateDir}
          mkdir -p "$state_dir"
          started=$(date +%s)
          : > "$state_dir/last-status"
          failed=0

          run_step() {
            local unit="$1" required="$2"
            local t0 t1
            t0=$(date +%s)
            echo "==> starting $unit"
            # `--wait` blocks until the (oneshot) unit finishes and
            # propagates its result, which is what lets us sequence
            # NixOS-then-HM without either owning a timer. A unit whose
            # ExecCondition/ConditionPathExists says "nothing to do" is
            # skipped and reports success, so re-running an already-done
            # oneshot every poll is free.
            if systemctl start --wait "$unit"; then
              t1=$(date +%s)
              echo "==> $unit: ok ($(( t1 - t0 ))s)"
              echo "$unit ok $(( t1 - t0 ))s" >> "$state_dir/last-status"
            elif [ "$required" = required ]; then
              t1=$(date +%s)
              echo "==> $unit: FAILED ($(( t1 - t0 ))s)" >&2
              echo "$unit FAILED $(( t1 - t0 ))s" >> "$state_dir/last-status"
              failed=1
            else
              t1=$(date +%s)
              echo "==> $unit: failed, continuing (best-effort) ($(( t1 - t0 ))s)" >&2
              echo "$unit failed-best-effort $(( t1 - t0 ))s" >> "$state_dir/last-status"
            fi
          }

          ${lib.concatMapStringsSep "\n" (u: ''run_step "${u}" best-effort'') bestEffortSteps}
          ${lib.concatMapStringsSep "\n" (u: ''run_step "${u}" required'') steps}

          date +%s > "$state_dir/last-run"
          finished=$(date +%s)
          echo "total $(( finished - started ))s" >> "$state_dir/last-status"

          if [ "$failed" -eq 0 ]; then
            date +%s > "$state_dir/last-success"
            echo ">> auto-update: all steps succeeded in $(( finished - started ))s"
            exit 0
          fi

          echo ">> auto-update: one or more required steps FAILED; see" >&2
          echo "   journalctl${lib.concatMapStrings (u: " -u ${u}") ([ "auto-update.service" ] ++ allSteps)}" >&2
          # Non-zero on purpose: `systemctl status auto-update.service`
          # and auto-update-status must show red. `last-success` is NOT
          # advanced, so the staleness fallback keeps trying outside the
          # quiet window until it works.
          exit 1
        '';
      };

      statusScript = pkgs.writeShellApplication {
        name = "auto-update-status";
        runtimeInputs = [ pkgs.coreutils config.systemd.package ];
        text = ''
          state_dir=${stateDir}
          echo "── auto-update on $(hostname) ──────────────────────────"
          echo "flake:      ${cfg.flake}"
          echo "steps:      ${if steps == [ ] then "(none)" else lib.concatStringsSep " -> " steps}"
          ${lib.optionalString (bestEffortSteps != [ ])
              ''echo "best-effort: ${lib.concatStringsSep " -> " bestEffortSteps} (failures don't block the run)"''}
          echo "window:     ${if cfg.quietWindow == null then "always" else "${cfg.quietWindow.start}-${cfg.quietWindow.end} (fallback after ${toString cfg.staleAfterHours}h)"}"
          echo "min gap:    ${toString cfg.minIntervalHours}h between attempts"
          echo "needs AC:   ${if cfg.requireAC then "yes" else "no"}"
          echo
          for f in last-attempt last-run last-success; do
            if [ -r "$state_dir/$f" ]; then
              ts=$(cat "$state_dir/$f")
              printf '%-14s %s (%s ago)\n' "$f:" \
                "$(date -d "@$ts" '+%Y-%m-%d %H:%M:%S')" \
                "$(printf '%dh%dm' $(( ( $(date +%s) - ts ) / 3600 )) $(( ( ( $(date +%s) - ts ) % 3600 ) / 60 )))"
            else
              printf '%-14s never\n' "$f:"
            fi
          done
          echo
          if [ -r "$state_dir/last-status" ]; then
            echo "last run per step:"
            sed 's/^/  /' "$state_dir/last-status"
            echo
          fi
          systemctl list-timers --all --no-pager auto-update.timer || true
          echo
          systemctl --no-pager --lines=0 status auto-update.service ${lib.concatStringsSep " " allSteps} 2>&1 \
            | grep -E '^(●|.?[A-Za-z ]*Loaded:|.?[A-Za-z ]*Active:|[[:space:]]*Process:)' || true
        '';
      };

      nowScript = pkgs.writeShellApplication {
        name = "auto-update-now";
        runtimeInputs = [ pkgs.coreutils config.systemd.package ];
        text = ''
          # Bypasses the gate entirely (window, AC, staleness,
          # reachability) — this is the "I want it now" button.
          echo "auto-update-now: starting auto-update.service with AUTO_UPDATE_FORCE=1"
          systemctl set-environment AUTO_UPDATE_FORCE=1 >/dev/null 2>&1 || true
          trap 'systemctl unset-environment AUTO_UPDATE_FORCE >/dev/null 2>&1 || true' EXIT
          systemctl start --wait auto-update.service
        '';
      };
    in
    {
      options.autoUpdate = {
        steps = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "nixos-auto-upgrade.service" "hm-auto-upgrade.service" ];
          description = ''
            Ordered list of oneshot units the sequencer runs, each via
            `systemctl start --wait`. A failure here fails the whole run
            and withholds the `last-success` stamp. Feature modules
            append with an explicit `lib.mkOrder` rather than relying on
            module import order:

              100  nixos-auto-upgrade.service
              200  hm-auto-upgrade.service

            An empty list (together with `bestEffortSteps`) disables the
            whole driver, which is what makes importing this module on a
            host with no auto-deploy feature modules a harmless no-op.
          '';
        };

        bestEffortSteps = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "nixos-clone-p.service" ];
          description = ''
            Units run *before* `steps`, whose failure is logged loudly
            and recorded in the status file but does NOT fail the run or
            withhold `last-success`.

            This exists for convenience work that must not be able to
            wedge the updater. `nixos-clone-<user>.service` is the
            motivating case: it is a `Type=oneshot`, so systemd will not
            let it carry `Restart=`, and being merely `WantedBy=
            multi-user.target` it gets exactly one attempt per boot. On
            a desktop that is rebooted once a month, a single transient
            DNS hiccup at boot means the clone never happens — silently,
            which is exactly what was observed on m-pc. Running it from
            here gives it a retry on every update poll.

            It must not be a required step, though: a clone that fails
            for a *persistent* reason (`~/nixos` exists, is non-empty,
            and isn't a repo) would otherwise withhold `last-success`
            forever, and the staleness fallback would then re-run a full
            `nixos-rebuild switch --refresh` on every poll — the exact
            unbounded-retry pathology `minIntervalHours` exists to
            prevent.
          '';
        };

        flake = lib.mkOption {
          type = lib.types.str;
          default = "github:dc0d32/nixos";
          description = ''
            Flake URI every auto-update step pulls from. Shared by
            flake-modules/auto-upgrade.nix (system closure) and
            flake-modules/hm-auto-upgrade.nix (per-user HM profiles) so
            the two can never drift onto different sources.
          '';
        };

        interval = lib.mkOption {
          type = lib.types.str;
          default = "1h";
          description = ''
            How often the sequencer wakes up to evaluate its gate while
            the machine is awake. This is a *poll*, not a schedule —
            most polls exit immediately via ExecCondition. Keep it
            comfortably shorter than the quiet window so a machine
            that's only briefly awake inside the window still gets a
            look-in.
          '';
        };

        quietWindow = lib.mkOption {
          type = lib.types.nullOr (lib.types.submodule {
            options = {
              start = lib.mkOption {
                type = lib.types.strMatching "[[:digit:]]{2}:[[:digit:]]{2}";
                description = "Local time the preferred window opens.";
              };
              end = lib.mkOption {
                type = lib.types.strMatching "[[:digit:]]{2}:[[:digit:]]{2}";
                description = "Local time the preferred window closes.";
              };
            };
          });
          default = { start = "02:00"; end = "09:00"; };
          description = ''
            Preferred time-of-day window for updating. Set to null to
            allow updates at any hour. Windows that wrap midnight
            (start > end) are supported.

            The morning edge is deliberately late: a laptop suspended
            overnight is opened somewhere between 07:00 and 09:00, and
            that wake is the realistic opportunity to update it.
          '';
        };

        staleAfterHours = lib.mkOption {
          type = lib.types.ints.positive;
          default = 24;
          description = ''
            Outside `quietWindow`, run anyway once the last *successful*
            run is older than this. Without this fallback a machine that
            is only ever used during the day never updates at all —
            which is precisely the failure mode the pure-calendar design
            had.
          '';
        };

        minIntervalHours = lib.mkOption {
          type = lib.types.ints.positive;
          default = 6;
          description = ''
            Minimum time between *attempts*, regardless of window or
            staleness. This is the rate limit, and it is not optional:
            the quiet window is 7h wide and the timer polls hourly, so
            without it any host awake overnight would run the whole
            sequence ~7 times a night, and a host with a persistently
            failing step would never advance its `last-success` stamp
            and so would run a full `nixos-rebuild switch --refresh`
            every hour forever.

            Stamped by the gate when it decides to proceed, not by the
            sequencer when it finishes, so a run killed by
            `TimeoutStartSec` or by a shutdown mid-switch still counts.

            `auto-update-now` bypasses it, as it does every other check.
          '';
        };

        requireAC = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Refuse to update on battery. Uses
            `flake.lib.mkAcCheck` (flake-modules/power-gate.nix), which
            understands sysfs Mains/USB-PD supplies and, inside WSL,
            asks Windows for the host's power-line status. A machine
            whose power state can't be determined proceeds anyway.
          '';
        };

        networkWaitSeconds = lib.mkOption {
          type = lib.types.ints.positive;
          default = 120;
          description = ''
            How long the gate waits for the flake host to become
            reachable before giving up on this poll. Bounded and short:
            the point is to absorb "WiFi hasn't associated yet, we only
            just woke up", not to sit blocked for hours.
          '';
        };

        triggerOnAC = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Install a udev rule that pokes the sequencer when a Mains
            supply comes online, so plugging in during the quiet window
            starts an update immediately instead of at the next poll.
            The gate still runs, so a poke outside the window is a
            no-op, and `minIntervalHours` keeps unplug/replug cycling
            from turning into a rebuild storm.
          '';
        };
      };

      config = lib.mkIf (allSteps != [ ]) {
        systemd.services.auto-update = {
          description = "Opportunistic system + home-manager update";

          # This unit orchestrates a `nixos-rebuild switch`, which will
          # daemon-reload and restart changed units mid-flight. Without
          # these three it can be restarted or stopped out from under
          # itself by the very switch it is driving.
          restartIfChanged = false;
          stopIfChanged = false;
          unitConfig.X-StopOnRemoval = false;

          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];

          serviceConfig = {
            Type = "oneshot";
            User = "root";
            # ExecCondition (not ExecStartPre): a "not now" answer must
            # leave the unit in `inactive`, not `failed`, or every
            # skipped poll would look like a broken updater.
            ExecCondition = "${gateScript}/bin/auto-update-gate";
            ExecStart = "${runScript}/bin/auto-update-run";
            StateDirectory = "auto-update";
            # Cold substituters + a full system closure + N home
            # activations. Generous on purpose.
            TimeoutStartSec = "3h";
          };
        };

        systemd.timers.auto-update = {
          description = "Poll for a good moment to auto-update";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            # Monotonic, not calendar. systemd's monotonic timers run
            # off CLOCK_BOOTTIME, so suspend counts against them and a
            # machine that wakes after a long sleep fires promptly
            # instead of waiting for tomorrow's calendar slot.
            OnBootSec = "10min";
            OnUnitActiveSec = cfg.interval;
            # Spread hosts out so four machines don't hit GitHub in the
            # same second.
            RandomizedDelaySec = "10min";
            AccuracySec = "1min";
          };
        };

        services.udev.extraRules = lib.mkIf cfg.triggerOnAC ''
          # Plugging in the charger is the single best signal that now
          # is a good moment to update. The unit's ExecCondition still
          # decides, so this only ever *offers* an opportunity.
          SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="1", TAG+="systemd", ENV{SYSTEMD_WANTS}+="auto-update.service"
        '';

        environment.systemPackages = [ statusScript nowScript acCheck ];
      };
    };
}
