{ pkgs }:

pkgs.writeShellApplication {
  name = "new-host";
  runtimeInputs = with pkgs; [ coreutils gnused git findutils ];
  text = ''
    set -euo pipefail

    usage() {
      echo "Usage: nix run .#new-host -- <hostname> [--user <username>] [--mac]" >&2
      exit 1
    }

    [ $# -ge 1 ] || usage
    HOSTNAME="$1"; shift

    USER_NAME="''${USER:-$(id -un)}"
    MAC=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --user) USER_NAME="$2"; shift 2 ;;
        --mac)  MAC=1; shift ;;
        -h|--help) usage ;;
        *) echo "unknown arg: $1" >&2; usage ;;
      esac
    done

    # Find the flake root (directory containing flake.nix). We walk up from $PWD.
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

    if [ "$MAC" -eq 1 ]; then
      # Pick a darwin system based on uname
      ARCH="$(uname -m)"
      case "$ARCH" in
        arm64|aarch64) SYSTEM="aarch64-darwin" ;;
        x86_64)        SYSTEM="x86_64-darwin" ;;
        *) echo "unknown mac arch: $ARCH" >&2; exit 1 ;;
      esac
      sed -i -e "s|system = \"x86_64-linux\"|system = \"$SYSTEM\"|" "$HOST_DIR/variables.nix"
      # On mac we only need the homes entry; drop hardware-configuration.nix
      rm -f "$HOST_DIR/hardware-configuration.nix"
      # Strip its import from configuration.nix
      sed -i -e '/hardware-configuration.nix/d' "$HOST_DIR/configuration.nix"
      echo ">> mac host — skipping nixos-generate-config"
    else
      if command -v nixos-generate-config >/dev/null 2>&1; then
        echo ">> generating hardware-configuration.nix (requires sudo)"
        sudo nixos-generate-config --show-hardware-config > "$HOST_DIR/hardware-configuration.nix"
      else
        echo "!! nixos-generate-config not found — leaving placeholder. Run it manually before rebuild:" >&2
        echo "   sudo nixos-generate-config --show-hardware-config > $HOST_DIR/hardware-configuration.nix" >&2
      fi
    fi

    echo ">> opening $HOST_DIR/variables.nix in \$EDITOR"
    "''${EDITOR:-vi}" "$HOST_DIR/variables.nix"

    git add -A "$HOST_DIR" "$HOME_DIR" || true

    echo
    echo "Done. Next steps:"
    if [ "$MAC" -eq 1 ]; then
      echo "  nix run home-manager/master -- switch --flake .#$USER_NAME@$HOSTNAME"
    else
      echo "  sudo nixos-rebuild switch --flake .#$HOSTNAME"
      echo "  nix run home-manager/master -- switch --flake .#$USER_NAME@$HOSTNAME   # optional: standalone HM"
    fi
  '';
}
