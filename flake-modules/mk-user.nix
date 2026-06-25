# Factory for a NixOS `users.users.<name>` entry.
#
# The bare-metal bridges (pb-x1, m-pc, pb-t480, ah-1) each hand-wrote a
# near-identical account block (isNormalUser, description, shell = zsh,
# initialPassword = "changeme", extraGroups). This publishes the shared
# shape on `flake.lib.mkUser` so a bridge writes:
#
#   users.users.alice = config.flake.lib.mkUser {
#     name = "alice";
#     admin = true;                       # adds the `wheel` group
#     extraGroups = [ "video" "audio" ];
#     shell = pkgs.zsh;
#   };
#
# `networkmanager` is always included (every account in the flake needs
# it). The caller passes `shell` explicitly because the host already has
# a `pkgs` instance to hand (hmPkgs / the module's pkgs).
#
# Retire when: NixOS grows a first-class per-host account preset, OR the
#   accounts diverge enough that a shared shape stops paying off.
{ lib, ... }:
{
  flake.lib.mkUser =
    { name
    , shell
    , extraGroups ? [ ]
    , admin ? false
    , initialPassword ? "changeme"
    }: {
      isNormalUser = true;
      description = name;
      inherit shell initialPassword;
      extraGroups =
        lib.optionals admin [ "wheel" ]
        ++ [ "networkmanager" ]
        ++ extraGroups;
    };
}
