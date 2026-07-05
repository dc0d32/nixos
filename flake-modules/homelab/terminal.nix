# terminal.nix — homelab-specific terminal extras (HM), layered on top of
# the base shell experience (zsh.nix: starship/eza/atuin/fzf/zoxide/bat/…).
#
# Why this exists:
#   SSHing into a homelab node should feel like the desktop terminal, plus
#   the tools you actually reach for on a container + storage host. The base
#   bundle already provides the shell/prompt/modern-CLI customization; this
#   module adds the homelab-flavored extras (docker/ZFS TUIs + aliases) so
#   they aren't scattered across host bridges.
#
# All userland (no root/caps needed to install). Aliases are plain strings,
# harmless on a host that lacks docker or zfs.
#
# Retire when: the homelab terminal toolset is folded into a broader shared
#   HM module, or these tools are superseded.
{ ... }:
{
  flake.modules.homeManager.homelab-terminal = { pkgs, ... }: {
    home.packages = with pkgs; [
      # containers
      lazydocker # docker TUI
      ctop # container metrics (top for containers)
      dive # inspect image layers
      # disk / storage
      duf # df, prettier
      dust # du, as a tree
      ncdu # interactive disk usage
      # process / watch
      procs # ps, modern
      viddy # watch, modern (great for `viddy docker ps`)
      # net / http
      doggo # dig, friendlier DNS
      curlie # curl + httpie ergonomics
      # misc
      pv # pipe throughput meter
      just # task runner (per-stack recipes)
    ];

    # Merged with the aliases from zsh.nix (HM merges shellAliases).
    programs.zsh.shellAliases = {
      # docker / compose
      dc = "docker compose";
      dcu = "docker compose up -d";
      dcd = "docker compose down";
      dcl = "docker compose logs -f";
      dcp = "docker compose pull";
      dps = "docker ps";
      dpsa = "docker ps -a";
      dex = "docker exec -it";
      lzd = "lazydocker";
      # zfs
      zl = "zpool list";
      zst = "zpool status";
      zfl = "zfs list";
      zsnap = "zfs list -t snapshot";
      # net
      ports = "ss -tulpn";
    };
  };
}
