{ pkgs }:

pkgs.writeShellApplication {
  name = "new-host";
  runtimeInputs = with pkgs; [ coreutils git ];
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
    FLAVOR="linux"  # one of: linux | mac | wsl
    while [ $# -gt 0 ]; do
      case "$1" in
        --user) USER_NAME="$2"; shift 2 ;;
        --mac)
          [ "$FLAVOR" = "linux" ] || { echo "error: --mac and --wsl are mutually exclusive" >&2; exit 1; }
          FLAVOR="mac"; shift ;;
        --wsl)
          [ "$FLAVOR" = "linux" ] || { echo "error: --mac and --wsl are mutually exclusive" >&2; exit 1; }
          FLAVOR="wsl"; shift ;;
        -h|--help) usage ;;
        *) echo "unknown arg: $1" >&2; usage ;;
      esac
    done

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

    # Resolve target system + per-flavor feature flags.
    # All booleans below are emitted verbatim into the generated variables.nix.
    ARCH="$(uname -m)"
    case "$FLAVOR" in
      mac)
        case "$ARCH" in
          arm64|aarch64) SYSTEM="aarch64-darwin" ;;
          x86_64)        SYSTEM="x86_64-darwin" ;;
          *) echo "unknown mac arch: $ARCH" >&2; exit 1 ;;
        esac
        WSL_ENABLE=false
        NIRI_ENABLE=false
        WAYBAR_ENABLE=false
        QUICKSHELL_ENABLE=false
        WALLPAPER_ENABLE=false
        PIPEWIRE_ENABLE=false
        EASYEFFECTS_ENABLE=false
        GPU_DRIVER="none"
        LY_ENABLE=false
        IDLE_ENABLE=false
        CHROME_ENABLE=false
        VSCODE_ENABLE=true
        BITWARDEN_ENABLE=false
        BIOMETRICS_ENABLE=false
        HARDWARE_HACKING_ENABLE=false
        SSH_AGENT_ENABLE=true
        ;;
      wsl)
        case "$ARCH" in
          arm64|aarch64) SYSTEM="aarch64-linux" ;;
          x86_64)        SYSTEM="x86_64-linux" ;;
          *) echo "unknown WSL arch: $ARCH" >&2; exit 1 ;;
        esac
        WSL_ENABLE=true
        NIRI_ENABLE=false
        WAYBAR_ENABLE=false
        QUICKSHELL_ENABLE=false
        WALLPAPER_ENABLE=false
        PIPEWIRE_ENABLE=false
        EASYEFFECTS_ENABLE=false
        GPU_DRIVER="none"
        LY_ENABLE=false
        IDLE_ENABLE=false
        CHROME_ENABLE=false
        VSCODE_ENABLE=false
        BITWARDEN_ENABLE=false
        BIOMETRICS_ENABLE=false
        HARDWARE_HACKING_ENABLE=false
        SSH_AGENT_ENABLE=true
        ;;
      linux)
        SYSTEM="x86_64-linux"
        WSL_ENABLE=false
        NIRI_ENABLE=true
        WAYBAR_ENABLE=false
        QUICKSHELL_ENABLE=true
        WALLPAPER_ENABLE=false
        PIPEWIRE_ENABLE=true
        EASYEFFECTS_ENABLE=false
        GPU_DRIVER="intel"
        LY_ENABLE=true
        IDLE_ENABLE=true
        CHROME_ENABLE=true
        VSCODE_ENABLE=true
        BITWARDEN_ENABLE=false
        BIOMETRICS_ENABLE=false
        HARDWARE_HACKING_ENABLE=false
        SSH_AGENT_ENABLE=true
        ;;
    esac

    echo ">> scaffolding $HOST_DIR from hosts/_template"
    cp -r hosts/_template "$HOST_DIR"

    echo ">> scaffolding $HOME_DIR from homes/_template"
    cp -r homes/_template "$HOME_DIR"

    # Generate variables.nix from scratch instead of sed-patching the template.
    # Single source of truth here; the _template/variables.nix only exists for
    # humans browsing the repo and as a fallback when copying non-variables files.
    cat > "$HOST_DIR/variables.nix" <<EOF
{
  # Host identity
  hostname = "$HOSTNAME";
  user = "$USER_NAME";

  # Architecture & release
  system = "$SYSTEM";
  stateVersion = "25.11";

  # Locale / time
  timezone = "America/Los_Angeles";
  locale = "en_US.UTF-8";
  keymap = "us";

  # --- Feature flags consumed by modules/nixos/* and modules/home/* ---

  desktop = {
    niri.enable = $NIRI_ENABLE;
    # Pick ONE status bar / shell. Enabling both will draw two panels.
    waybar.enable = $WAYBAR_ENABLE;
    quickshell.enable = $QUICKSHELL_ENABLE;
    # Wallpaper: downloads random nature photos from wallhaven, cycles every 30 min.
    # \`directory\` defaults to \$HOME/.wallpaper; override only if you want it
    # somewhere else.
    wallpaper = {
      enable = $WALLPAPER_ENABLE;
      intervalMinutes = 30;
    };
  };

  audio.pipewire.enable = $PIPEWIRE_ENABLE;

  audio.easyeffects = {
    enable = $EASYEFFECTS_ENABLE;
  };

  # Graphics driver. One of: "intel" | "amd" | "nvidia" | "none"
  # Consumed by modules/nixos/gpu.nix.
  gpu = {
    driver = "$GPU_DRIVER";
  };

  # Login manager (ly — tiny TUI DM)
  login.ly.enable = $LY_ENABLE;

  # Auto-lock / DPMS / suspend timings (seconds). Applied by
  # modules/home/desktop/idle.nix via stasis under the user's session.
  idle = {
    enable = $IDLE_ENABLE;
    lockAfter    = 300;   # 5 min
    dpmsAfter    = 420;   # 7 min
    suspendAfter = 900;   # 15 min
  };

  # WSL (Windows Subsystem for Linux). When enabled, modules/nixos/wsl.nix
  # imports wsl.nix from github:dc0d32/nixos-aarch64-wsl and disables
  # bootloader/DM/niri/pipewire/gpu/power.
  wsl = {
    enable = $WSL_ENABLE;
    # defaultUser falls back to variables.user automatically
  };

  apps = {
    chrome.enable = $CHROME_ENABLE;
    vscode.enable = $VSCODE_ENABLE;
    bitwarden.enable = $BITWARDEN_ENABLE;
  };

  # Biometrics: fingerprint reader + IR face auth (howdy).
  # Requires one-time setup after first rebuild — see README.
  biometrics.enable = $BIOMETRICS_ENABLE;

  # Hardware hacking: USB serial / JTAG / flashing tools and udev rules.
  hardwareHacking.enable = $HARDWARE_HACKING_ENABLE;

  # SSH agent: systemd socket-activated ssh-agent for the user session.
  sshAgent.enable = $SSH_AGENT_ENABLE;

  # Optional git identity merged into modules/home/git.nix
  git = {
    name  = "CHANGEME";
    email = "CHANGEME@example.com";
  };
}
EOF

    # Per-flavor cleanup of files copied from _template that don't apply.
    case "$FLAVOR" in
      mac|wsl)
        # nixos-wsl owns boot inside WSL; macOS doesn't use NixOS at all.
        # Either way the placeholder hardware-configuration.nix is dead weight.
        rm -f "$HOST_DIR/hardware-configuration.nix"
        # Drop the import line. The template uses a single-line import block,
        # so we rewrite configuration.nix rather than sed-patching it: copy
        # everything except the offending line.
        grep -v 'hardware-configuration.nix' "$HOST_DIR/configuration.nix" \
          > "$HOST_DIR/configuration.nix.new"
        mv "$HOST_DIR/configuration.nix.new" "$HOST_DIR/configuration.nix"
        ;;
    esac

    case "$FLAVOR" in
      mac) echo ">> mac host ($SYSTEM) — skipping nixos-generate-config" ;;
      wsl) echo ">> WSL host ($SYSTEM) — skipping nixos-generate-config; nixos-wsl owns boot" ;;
      linux)
        if command -v nixos-generate-config >/dev/null 2>&1; then
          echo ">> generating hardware-configuration.nix (requires sudo)"
          sudo nixos-generate-config --show-hardware-config | sudo tee "$HOST_DIR/hardware-configuration.nix" >/dev/null
        else
          echo "!! nixos-generate-config not found — leaving placeholder. Run it manually before rebuild:" >&2
          echo "   sudo nixos-generate-config --show-hardware-config | sudo tee $HOST_DIR/hardware-configuration.nix" >&2
        fi
        ;;
    esac

    echo ">> opening $HOST_DIR/variables.nix in \$EDITOR"
    "''${EDITOR:-vi}" "$HOST_DIR/variables.nix"

    git add -A "$HOST_DIR" "$HOME_DIR" || true

    echo
    echo "Done. Next steps:"
    case "$FLAVOR" in
      mac)
        echo "  nix run home-manager/master -- switch --flake .#$USER_NAME@$HOSTNAME"
        ;;
      wsl)
        echo "  sudo nixos-rebuild switch --flake .#$HOSTNAME"
        echo "  # Inside WSL, restart the distro after the first switch:"
        echo "  # (from Windows)  wsl --terminate <distro-name>"
        echo "  nix run home-manager/master -- switch --flake .#$USER_NAME@$HOSTNAME"
        ;;
      linux)
        echo "  sudo nixos-rebuild switch --flake .#$HOSTNAME"
        echo "  nix run home-manager/master -- switch --flake .#$USER_NAME@$HOSTNAME   # optional: standalone HM"
        ;;
    esac
  '';
}
