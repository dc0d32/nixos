{ pkgs }:

pkgs.writeShellApplication {
  name = "new-host";
  runtimeInputs = with pkgs; [ coreutils gnused git findutils ];
  text = ''
    set -euo pipefail

    usage() {
      echo "Usage: nix run .#new-host -- <hostname> [--user <name>] [--mac | --wsl]" >&2
      echo "  --mac   target macOS (home-manager only)" >&2
      echo "  --wsl   target NixOS inside WSL2 (x86_64 or aarch64)" >&2
      exit 1
    }

    [ $# -ge 1 ] || usage
    HOSTNAME="$1"; shift

    USER_NAME="''${USER:-$(id -un)}"
    MAC=0
    WSL=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --user) USER_NAME="$2"; shift 2 ;;
        --mac)  MAC=1; shift ;;
        --wsl)  WSL=1; shift ;;
        -h|--help) usage ;;
        *) echo "unknown arg: $1" >&2; usage ;;
      esac
    done

    if [ "$MAC" -eq 1 ] && [ "$WSL" -eq 1 ]; then
      echo "error: --mac and --wsl are mutually exclusive" >&2
      exit 1
    fi

    # Find the flake root (directory containing flake.nix). Walk up from $PWD.
    ROOT="$PWD"
    while [ "$ROOT" != "/" ] && [ ! -f "$ROOT/flake.nix" ]; do
      ROOT="$(dirname "$ROOT")"
    done
    if [ ! -f "$ROOT/flake.nix" ]; then
      echo "error: not inside a flake (no flake.nix found walking up from $PWD)" >&2
      exit 1
    fi
    cd "$ROOT"

    HOST_DIR="hosts/$HOSTNAME"
    HOME_DIR="homes/$USER_NAME@$HOSTNAME"

    if [ -e "$HOST_DIR" ]; then
      echo "error: $HOST_DIR already exists" >&2
      exit 1
    fi
    if [ -e "$HOME_DIR" ]; then
      echo "error: $HOME_DIR already exists" >&2
      exit 1
    fi

    echo ">> scaffolding $HOST_DIR from hosts/_template"
    cp -r hosts/_template "$HOST_DIR"

    echo ">> scaffolding $HOME_DIR from homes/_template"
    cp -r homes/_template "$HOME_DIR"

    # Fill in hostname + user in the new variables.nix
    sed -i \
      -e "s|hostname = \"CHANGEME\"|hostname = \"$HOSTNAME\"|" \
      -e "s|user = \"CHANGEME\"|user = \"$USER_NAME\"|" \
      "$HOST_DIR/variables.nix"

    ARCH="$(uname -m)"

    if [ "$MAC" -eq 1 ]; then
      case "$ARCH" in
        arm64|aarch64) SYSTEM="aarch64-darwin" ;;
        x86_64)        SYSTEM="x86_64-darwin" ;;
        *) echo "unknown mac arch: $ARCH" >&2; exit 1 ;;
      esac
      sed -i -e "s|system = \"x86_64-linux\"|system = \"$SYSTEM\"|" "$HOST_DIR/variables.nix"
      rm -f "$HOST_DIR/hardware-configuration.nix"
      sed -i -e '/hardware-configuration.nix/d' "$HOST_DIR/configuration.nix"
      echo ">> mac host — skipping nixos-generate-config"

    elif [ "$WSL" -eq 1 ]; then
      case "$ARCH" in
        arm64|aarch64) SYSTEM="aarch64-linux" ;;
        x86_64)        SYSTEM="x86_64-linux" ;;
        *) echo "unknown WSL arch: $ARCH" >&2; exit 1 ;;
      esac
      sed -i -e "s|system = \"x86_64-linux\"|system = \"$SYSTEM\"|" "$HOST_DIR/variables.nix"

      # Flip all WSL-sensitive defaults off, WSL on
      sed -i \
        -e "s|wsl = {|wsl = {\n    # (set by new-host --wsl)|" \
        -e "s|enable = false;\n    # defaultUser|enable = true;\n    # defaultUser|" \
        "$HOST_DIR/variables.nix" || true
      # sed above is best-effort across platforms. Do authoritative replacements:
      # Enable WSL
      sed -i -e '/^  wsl = {/,/^  };/ s|enable = false;|enable = true;|' "$HOST_DIR/variables.nix"
      # Disable niri + bars + chrome (no GUI in WSL base)
      sed -i \
        -e '/^  desktop = {/,/^  };/ s|niri.enable = true;|niri.enable = false;|' \
        -e '/^  desktop = {/,/^  };/ s|waybar.enable = true;|waybar.enable = false;|' \
        -e '/^  desktop = {/,/^  };/ s|quickshell.enable = true;|quickshell.enable = false;|' \
        "$HOST_DIR/variables.nix"
      sed -i -e '/^  audio\.pipewire\.enable/ s|true|false|' "$HOST_DIR/variables.nix"
      sed -i -e '/^  login\.ly\.enable/ s|true|false|' "$HOST_DIR/variables.nix"
      sed -i -e '/^  idle = {/,/^  };/ s|enable = true;|enable = false;|' "$HOST_DIR/variables.nix"
       sed -i -e '/^  apps = {/,/^  };/ s|chrome.enable = true;|chrome.enable = false;|' "$HOST_DIR/variables.nix"
       sed -i -e '/^  apps = {/,/^  };/ s|bitwarden.enable = true;|bitwarden.enable = false;|' "$HOST_DIR/variables.nix"
       sed -i -e 's|biometrics.enable = true;|biometrics.enable = false;|' "$HOST_DIR/variables.nix"
       sed -i -e 's|sshAgent.enable = true;|sshAgent.enable = false;|' "$HOST_DIR/variables.nix"
      # GPU none (WSLg handles GPU itself)
      sed -i -e '/^  gpu = {/,/^  };/ s|driver = "intel";|driver = "none";|' "$HOST_DIR/variables.nix"

      # nixos-wsl supplies its own hardware-configuration equivalent; drop placeholder
      rm -f "$HOST_DIR/hardware-configuration.nix"
      sed -i -e '/hardware-configuration.nix/d' "$HOST_DIR/configuration.nix"

      echo ">> WSL host ($SYSTEM) — skipping nixos-generate-config; nixos-wsl owns boot"

    else
      if command -v nixos-generate-config >/dev/null 2>&1; then
        echo ">> generating hardware-configuration.nix (requires sudo)"
        sudo nixos-generate-config --show-hardware-config | sudo tee "$HOST_DIR/hardware-configuration.nix" >/dev/null
      else
        echo "!! nixos-generate-config not found — leaving placeholder. Run it manually before rebuild:" >&2
        echo "   sudo nixos-generate-config --show-hardware-config | sudo tee $HOST_DIR/hardware-configuration.nix" >&2
      fi
    fi

    echo ">> opening $HOST_DIR/variables.nix in \$EDITOR"
    "''${EDITOR:-vi}" "$HOST_DIR/variables.nix"

    git add -A "$HOST_DIR" "$HOME_DIR" || true

    echo
    echo "Done. Next steps:"
    if [ "$MAC" -eq 1 ]; then
      echo "  nix run home-manager/master -- switch --flake .#$USER_NAME@$HOSTNAME"
    elif [ "$WSL" -eq 1 ]; then
      echo "  sudo nixos-rebuild switch --flake .#$HOSTNAME"
      echo "  # Inside WSL, restart the distro after the first switch:"
      echo "  # (from Windows)  wsl --terminate <distro-name>"
      echo "  nix run home-manager/master -- switch --flake .#$USER_NAME@$HOSTNAME"
    else
      echo "  sudo nixos-rebuild switch --flake .#$HOSTNAME"
      echo "  nix run home-manager/master -- switch --flake .#$USER_NAME@$HOSTNAME   # optional: standalone HM"
    fi
  '';
}
