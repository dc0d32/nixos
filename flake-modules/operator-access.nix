# operator-access.nix — portable, unlock-once homelab access tooling.
#
# Why this exists:
#   Copilot and ordinary shells need the same SSH/SOPS session without exposing
#   passwords or private keys to command arguments, disk, or conversation logs.
#   These helpers prompt only on a real TTY, keep the age identity in runtime
#   storage, and load the operator SSH key directly into ssh-agent.
#
# Retire when: SSH and repository-encrypted secrets are replaced by an
# identity-aware access system with equivalent offline recovery.
{
  flake.modules.nixos.operator-access = {
    services.pcscd.enable = true;
  };

  flake.modules.homeManager.operator-access = { pkgs, ... }:
    let
      runtimeDir = ''
        if [[ -n "''${XDG_RUNTIME_DIR:-}" ]]; then
          printf '%s\n' "$XDG_RUNTIME_DIR/homelab-access"
        elif [[ -n "''${TMPDIR:-}" ]]; then
          printf '%s\n' "''${TMPDIR%/}/homelab-access-$UID"
        else
          printf '%s\n' "/tmp/homelab-access-$UID"
        fi
      '';

      homelabUnlock = pkgs.writeShellApplication {
        name = "homelab-unlock";
        runtimeInputs = with pkgs; [ age coreutils gnugrep openssh sops ];
        text = ''
          repo="''${HOMELAB_REPO:-$HOME/nixos/homelab}"
          wrapped="''${HOMELAB_AGE_IDENTITY:-$repo/secrets/operator/daily.age}"
          encrypted_key="$repo/secrets/operator/universal-ssh-key.sops.json"
          runtime="$(${runtimeDir})"
          identity="$runtime/daily-identity.txt"
          default_socket="$runtime/ssh-agent.sock"
          tmp_identity=""
          identity_created=0

          # shellcheck disable=SC2329
          cleanup_failed_unlock() {
            status=$?
            [[ -z "$tmp_identity" ]] || rm -f "$tmp_identity"
            if (( status != 0 && identity_created )); then
              rm -f "$identity"
            fi
          }
          trap cleanup_failed_unlock EXIT

          umask 077
          mkdir -p "$runtime"
          chmod 700 "$runtime"

          [[ -r "$wrapped" ]] || {
            echo "homelab-unlock: missing wrapped identity: $wrapped" >&2
            exit 1
          }
          [[ -r "$encrypted_key" ]] || {
            echo "homelab-unlock: missing encrypted SSH key: $encrypted_key" >&2
            exit 1
          }

          if [[ ! -s "$identity" ]]; then
            [[ -r /dev/tty && -w /dev/tty ]] || {
              echo "homelab-unlock: first unlock requires a real terminal" >&2
              exit 1
            }
            tmp_identity="$runtime/.daily-identity.$$"
            age --decrypt --output "$tmp_identity" "$wrapped"
            age-keygen -y "$tmp_identity" >/dev/null
            chmod 600 "$tmp_identity"
            mv "$tmp_identity" "$identity"
            tmp_identity=""
            identity_created=1
          fi

          socket="''${SSH_AUTH_SOCK:-}"
          socket_ok=0
          if [[ -n "$socket" && -S "$socket" ]]; then
            set +e
            SSH_AUTH_SOCK="$socket" ssh-add -l >/dev/null 2>&1
            status=$?
            set -e
            (( status < 2 )) && socket_ok=1
          fi
          if (( ! socket_ok )); then
            socket="$default_socket"
            if [[ -S "$socket" ]]; then
              set +e
              SSH_AUTH_SOCK="$socket" ssh-add -l >/dev/null 2>&1
              status=$?
              set -e
              (( status < 2 )) && socket_ok=1
            fi
          fi
          if (( ! socket_ok )); then
            rm -f "$socket"
            agent_output="$(ssh-agent -a "$socket" -s)"
            agent_pid="$(printf '%s\n' "$agent_output" |
              sed -n 's/^SSH_AGENT_PID=\([0-9][0-9]*\);.*$/\1/p')"
            [[ -n "$agent_pid" ]] || {
              echo "homelab-unlock: ssh-agent did not report its PID" >&2
              exit 1
            }
            printf '%s\n' "$agent_pid" >"$runtime/ssh-agent.pid"
          fi

          export SSH_AUTH_SOCK="$socket"
          export SOPS_AGE_KEY_FILE="$identity"
          sops --decrypt --output-type binary "$encrypted_key" |
            ssh-add -
          trap - EXIT

          echo "Homelab credentials unlocked for this login session."
          if [[ "''${SSH_AUTH_SOCK:-}" != "$default_socket" ]]; then
            echo "SSH agent: $SSH_AUTH_SOCK"
          fi
        '';
      };

      homelabLock = pkgs.writeShellApplication {
        name = "homelab-lock";
        runtimeInputs = with pkgs; [ coreutils gawk openssh ];
        text = ''
          repo="''${HOMELAB_REPO:-$HOME/nixos/homelab}"
          public_key="$repo/secrets/operator/universal-ssh-key.pub"
          runtime="$(${runtimeDir})"
          default_socket="$runtime/ssh-agent.sock"
          sockets=()
          if [[ -n "''${SSH_AUTH_SOCK:-}" ]]; then
            sockets+=("$SSH_AUTH_SOCK")
          fi
          if [[ "''${SSH_AUTH_SOCK:-}" != "$default_socket" ]]; then
            sockets+=("$default_socket")
          fi

          key_loaded() {
            target="$(awk '{ print $1 " " $2; exit }' "$public_key")"
            while read -r kind body _; do
              [[ "$kind $body" == "$target" ]] && return 0
            done < <(SSH_AUTH_SOCK="$socket" ssh-add -L 2>/dev/null || true)
            return 1
          }

          for socket in "''${sockets[@]}"; do
            if [[ -S "$socket" ]]; then
              [[ -r "$public_key" ]] || {
                echo "homelab-lock: missing public key: $public_key" >&2
                exit 1
              }
              if key_loaded; then
                SSH_AUTH_SOCK="$socket" ssh-add -d "$public_key" >/dev/null
              fi
              if key_loaded; then
                echo "homelab-lock: universal SSH key is still loaded in $socket" >&2
                exit 1
              fi
            fi
          done
          rm -f "$runtime/daily-identity.txt"
          echo "Homelab credentials locked."
        '';
      };

      homelabSudo = pkgs.writeShellApplication {
        name = "homelab-sudo";
        runtimeInputs = with pkgs; [ openssh ];
        text = ''
          mode=unlock
          if [[ "''${1:-}" == "--lock" ]]; then
            mode=lock
            shift
          fi
          [[ $# -eq 1 && "$1" != -* ]] || {
            echo "usage: homelab-sudo [--lock] <host|user@host>" >&2
            exit 2
          }
          target="$1"
          [[ "$target" == *@* ]] || target="p@$target"

          if [[ "$mode" == lock ]]; then
            exec ssh -o BatchMode=yes "$target" sudo -k
          fi
          [[ -r /dev/tty && -w /dev/tty ]] || {
            echo "homelab-sudo: password approval requires a real terminal" >&2
            exit 1
          }
          exec ssh -t "$target" sudo -v </dev/tty >/dev/tty
        '';
      };

      homelabCopilot = pkgs.writeShellApplication {
        name = "homelab-copilot";
        runtimeInputs = [ homelabSudo homelabUnlock pkgs.github-copilot-cli ];
        text = ''
          sudo_hosts=()
          while [[ "''${1:-}" == "--sudo" ]]; do
            [[ -n "''${2:-}" ]] || {
              echo "usage: homelab-copilot [--sudo <host>]... [--] [copilot arguments]" >&2
              exit 2
            }
            sudo_hosts+=("$2")
            shift 2
          done
          if [[ "''${1:-}" == "--" ]]; then
            shift
          fi

          runtime="$(${runtimeDir})"
          umask 077
          mkdir -p "$runtime"
          chmod 700 "$runtime"
          export SSH_AUTH_SOCK="$runtime/ssh-agent.sock"
          export SOPS_AGE_KEY_FILE="$runtime/daily-identity.txt"
          homelab-unlock

          approved_hosts=()
          # shellcheck disable=SC2329
          cleanup() {
            for host in "''${approved_hosts[@]}"; do
              homelab-sudo --lock "$host" || true
            done
          }
          trap cleanup EXIT
          trap 'exit 129' HUP
          trap 'exit 143' TERM

          for host in "''${sudo_hosts[@]}"; do
            homelab-sudo "$host"
            approved_hosts+=("$host")
          done

          set +e
          copilot "$@"
          status=$?
          set -e
          exit "$status"
        '';
      };

      homelabShell = pkgs.writeShellApplication {
        name = "homelab-shell";
        runtimeInputs = [ homelabUnlock ];
        text = ''
          runtime="$(${runtimeDir})"
          umask 077
          mkdir -p "$runtime"
          chmod 700 "$runtime"
          export SSH_AUTH_SOCK="$runtime/ssh-agent.sock"
          export SOPS_AGE_KEY_FILE="$runtime/daily-identity.txt"
          homelab-unlock
          if [[ $# -gt 0 ]]; then
            exec "$@"
          fi
          exec "''${SHELL:-bash}" -l
        '';
      };
    in
    {
      home.packages = with pkgs; [
        age
        age-plugin-yubikey
        homelabCopilot
        homelabLock
        homelabShell
        homelabSudo
        qrencode
        sops
        ssh-to-age
        yubikey-manager
      ];
    };
}
