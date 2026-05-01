# openssh.nix — SSH server (NixOS).
#
# Why this module exists:
#   The headless server-class hosts (ah-N homelab VMs) need remote
#   shell access to be usable at all -- there is no console session in
#   normal operation. Packaging openssh as a tiny dendritic module
#   means any future server-class host opts in by importing
#   `config.flake.modules.nixos.openssh`, and desktop hosts (pb-x1,
#   pb-t480) stay free of an SSH listener they never use.
#
# Why defaults rather than an opinionated hardening preset:
#   The host bridge (flake-modules/hosts/ah-1.nix) explicitly chose
#   "Defaults" for the SSH auth policy. Hardening (PermitRootLogin
#   prohibit-password, PasswordAuthentication false, key-only auth,
#   port hardening, fail2ban) is a follow-up that should happen as a
#   conscious decision once the host is reachable on the network.
#   When you do harden, the natural place is per-host overrides in the
#   ah-1.nix bridge, NOT this module -- this module stays a "just
#   enable sshd" primitive so other hosts with different policies can
#   share it.
#
# Why NixOS (not HM):
#   sshd is a system service (systemd unit, port bind, host keys at
#   /etc/ssh/), not a per-user concern.
#
# Retire when:
#   - Replaced by a centrally-managed remote-access mechanism that
#     supersedes SSH (e.g. Tailscale SSH with explicit ACLs and
#     identity-aware policy), AND
#   - No host in the repo still needs raw sshd as a fallback.
{
  flake.modules.nixos.openssh = {
    services.openssh.enable = true;
  };
}
