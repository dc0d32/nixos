# virt-host.nix — libvirt/QEMU capability for running guest VMs on a
# homelab node (HAOS; later the internet-edge microvm).
#
# Why this exists:
#   The model is bare-metal NixOS + VMs as a scalpel. HAOS stays a VM
#   guest (keeps its Supervisor/add-on ecosystem, Zigbee/Matter USB
#   passthrough), and the internet-facing edge gets a DMZ microvm. This
#   module turns a host into a libvirt hypervisor and puts the operator in
#   the libvirtd group. Actual guest domains (HAOS, edge) are declared
#   per-host later.
#
# libvirt now (in nixpkgs, no extra flake input); microvm.nix can be added
# as an input when the edge microvm is built.
#
# Inert until `homelab.virt.enable = true`.
#
# Retire when: guests move to microvm.nix exclusively, or the homelab has
#   no foreign-OS guests left.
{ ... }:
{
  flake.modules.nixos.virt-host = { config, lib, pkgs, ... }:
    let
      cfg = config.homelab.virt;
    in
    {
      options.homelab.virt.enable =
        lib.mkEnableOption "libvirt/QEMU host for guest VMs";

      config = lib.mkIf cfg.enable {
        virtualisation.libvirtd = {
          enable = true;
          qemu = {
            package = pkgs.qemu_kvm;
            # OVMF/UEFI firmware for guests ships by default now; the
            # explicit `qemu.ovmf.*` submodule was removed in nixpkgs 26.05.
            runAsRoot = false;
          };
        };
        # Shared-folder support for microvm/virtiofs guests.
        virtualisation.spiceUSBRedirection.enable = lib.mkDefault false;
        # Operator manages guests without sudo.
        users.users.${config.users.primary}.extraGroups = [ "libvirtd" ];
        environment.systemPackages = [ pkgs.virtiofsd ];
      };
    };
}
