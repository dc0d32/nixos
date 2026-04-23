{ lib, ... }: {
  # mkDefault so hosts / WSL can override. The upstream WSL fork disables
  # both of these; on bare-metal hosts these defaults apply.
  networking.networkmanager.enable = lib.mkDefault true;
  networking.firewall.enable = lib.mkDefault true;
}
