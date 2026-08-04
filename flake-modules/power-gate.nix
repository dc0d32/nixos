# power-gate — one shared "are we on wall power?" probe, exposed as
# `flake.lib.mkAcCheck`.
#
# Why this exists: two independent subsystems need to avoid doing heavy
# work on battery — `flake-modules/backup.nix` (restic over SFTP) and
# `flake-modules/auto-update.nix` (nixos-rebuild + home-manager switch).
# Before this module each carried its own hand-rolled sysfs poke, and
# backup's copy only knew four hardcoded node names
# (AC/ACAD/AC0/ADP1), which is wrong on any laptop whose mains supply
# is named something else (USB-PD-only machines expose
# `ucsi-source-psy-USBC000:001` with `type=USB`, no `AC` node at all).
#
# What it knows how to do, in order:
#   1. sysfs — scan every /sys/class/power_supply/* and look at its
#      `type`. `Mains` (and `USB`/`USB_PD*`, which is how USB-C-only
#      chargers show up) with `online == 1` means wall power. Nodes with
#      `scope=Device` are skipped: bluetooth mice, keyboards, headsets,
#      gamepads and Wacom pens all publish `type=Battery`, and counting
#      them as a system battery makes a *desktop* report BATTERY the
#      moment a peripheral pairs.
#   2. WSL — WSL2's kernel exposes no power_supply class at all
#      (the VM has no virtual battery), so if there is no Battery node
#      AND we're clearly inside WSL, ask Windows over interop for
#      `SystemInformation.PowerStatus.PowerLineStatus`. A system
#      service has no `WSL_INTEROP` in its environment, so we recover
#      one from /run/WSL/*_interop (the per-session interop sockets
#      the WSL init creates) before exec'ing powershell.exe.
#   3. No battery anywhere and not WSL → desktop / VM / server. Always
#      "on AC".
#
# Exit codes of the generated `ac-check` binary:
#   0  on wall power (or no battery exists → nothing to protect)
#   1  on battery
#   2  could not determine (broken interop, weird sysfs). Callers
#      decide; both current callers treat 2 as "proceed", because
#      wedging updates/backups forever on an undetectable machine is
#      worse than occasionally running on battery.
#
# Usage from a NixOS module:
#   acCheck = config.flake.lib.mkAcCheck { inherit pkgs; };
#   … "${acCheck}/bin/ac-check" …
# and `ac-check --verbose` to get the reasoning on stderr.
#
# Retire when: every host either has a real sysfs Mains node or is a
#   desktop (i.e. the WSL branch stops earning its keep), OR upstream
#   NixOS grows a first-class "on AC" condition for units (systemd has
#   discussed `ConditionACPower=` for years; if it lands, both callers
#   collapse to a one-line unit condition and this module goes away).
{ ... }:
{
  flake.lib.mkAcCheck = { pkgs }:
    pkgs.writeShellApplication {
      name = "ac-check";
      runtimeInputs = [ pkgs.coreutils pkgs.findutils ];
      text = ''
        verbose=0
        if [ "''${1:-}" = "--verbose" ] || [ "''${1:-}" = "-v" ]; then
          verbose=1
        fi
        log() { [ "$verbose" -eq 1 ] && echo "ac-check: $*" >&2; return 0; }

        psdir=/sys/class/power_supply

        # ── 1. sysfs ────────────────────────────────────────────────
        # A "line power" supply is anything whose type is Mains or a
        # USB flavour (USB, USB_PD, USB_PD_DRP, USB_C, …). Laptops with
        # only USB-C charging have no Mains node.
        have_battery=0
        have_line=0
        line_online=0
        if [ -d "$psdir" ]; then
          while IFS= read -r node; do
            [ -n "$node" ] || continue
            type=""
            [ -r "$node/type" ] && type=$(cat "$node/type" 2>/dev/null || true)
            scope=""
            [ -r "$node/scope" ] && scope=$(cat "$node/scope" 2>/dev/null || true)
            # Peripheral batteries — bluetooth mice, keyboards, headsets,
            # gamepads, Wacom pens — register as `type=Battery` with
            # `scope=Device`. Counting them as "this machine has a
            # battery" makes a desktop flip to the battery-present
            # branch the moment a headset pairs, and from there any
            # line-power node reading online=0 (idle USB-C ports do)
            # yields a verdict of BATTERY. That is a desktop that
            # silently stops updating and backing up depending on what
            # is paired.
            case "$scope" in
              Device) log "$node: scope=Device (peripheral), ignoring"; continue ;;
              *) ;;
            esac
            case "$type" in
              Battery)
                have_battery=1
                ;;
              Mains | USB*)
                [ -r "$node/online" ] || continue
                have_line=1
                if [ "$(cat "$node/online" 2>/dev/null || echo 0)" = "1" ]; then
                  line_online=1
                  log "$node ($type) is online"
                fi
                ;;
              *) ;;
            esac
          done <<< "$(find "$psdir" -mindepth 1 -maxdepth 1 2>/dev/null || true)"
        fi

        if [ "$have_battery" -eq 0 ] && [ "$have_line" -eq 1 ]; then
          log "line power present and no system battery -> AC"
          exit 0
        fi

        if [ "$have_battery" -eq 1 ] && [ "$have_line" -eq 1 ]; then
          if [ "$line_online" -eq 1 ]; then
            log "battery present, line power online -> AC"
            exit 0
          fi
          log "battery present, no line power online -> BATTERY"
          exit 1
        fi

        if [ "$have_battery" -eq 1 ] && [ "$have_line" -eq 0 ]; then
          # A system battery but no readable mains/USB supply at all.
          # Reporting AC here (which is where this used to fall through
          # to) would run a full closure download on a laptop that is
          # demonstrably portable. Reporting BATTERY would wedge it
          # forever. UNKNOWN lets each caller decide.
          log "system battery present but no readable line-power node -> UNKNOWN"
          exit 2
        fi

        # ── 2. WSL ─────────────────────────────────────────────────
        # No usable sysfs. If we're inside WSL the *host* may well be a
        # laptop on battery, so ask Windows.
        is_wsl=0
        if [ -e /proc/sys/fs/binfmt_misc/WSLInterop ] \
          || [ -e /proc/sys/fs/binfmt_misc/WSLInterop-late ] \
          || [ -d /run/WSL ] \
          || grep -qi 'microsoft' /proc/sys/kernel/osrelease 2>/dev/null; then
          is_wsl=1
        fi

        if [ "$is_wsl" -eq 1 ]; then
          pwsh=""
          for cand in \
            /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
            /c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe; do
            if [ -x "$cand" ]; then pwsh="$cand"; break; fi
          done

          if [ -z "$pwsh" ]; then
            log "WSL detected but no powershell.exe reachable -> UNKNOWN"
            exit 2
          fi

          # A system service inherits no WSL_INTEROP. Borrow the most
          # recently created per-session interop socket; without it the
          # binfmt handler refuses to launch the .exe.
          if [ -z "''${WSL_INTEROP:-}" ]; then
            sock=$(find /run/WSL -maxdepth 1 -name '*_interop' -printf '%T@ %p\n' 2>/dev/null \
                     | sort -rn | head -n1 | cut -d' ' -f2- || true)
            if [ -n "$sock" ]; then
              export WSL_INTEROP="$sock"
              log "using interop socket $sock"
            else
              log "WSL detected but no /run/WSL/*_interop socket -> UNKNOWN"
              exit 2
            fi
          fi

          # PowerLineStatus is Online / Offline / Unknown. It needs no
          # elevation, unlike root\wmi's BatteryStatus class.
          out=$("$pwsh" -NoProfile -NonInteractive -Command \
                 "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus" \
                 2>/dev/null | tr -d '\r\n ' || true)
          case "$out" in
            Online)
              log "Windows reports PowerLineStatus=Online -> AC"
              exit 0
              ;;
            Offline)
              log "Windows reports PowerLineStatus=Offline -> BATTERY"
              exit 1
              ;;
            *)
              log "Windows reports PowerLineStatus='$out' -> UNKNOWN"
              exit 2
              ;;
          esac
        fi

        # ── 3. no battery, not WSL ─────────────────────────────────
        log "no battery and no line-power node -> desktop/VM, treating as AC"
        exit 0
      '';
    };
}
