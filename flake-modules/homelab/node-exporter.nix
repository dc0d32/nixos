# node-exporter.nix — Prometheus node exporter for homelab hosts.
#
# Why this exists:
#   Time-series system metrics (CPU, memory, filesystem, disk I/O, network,
#   ZFS, systemd unit states) for the draco Prometheus + Grafana observability
#   stack. Complements the ntfy/Kuma alerting (which answers "is it up / did a
#   job fail") with dashboards + history ("why is it slow / when did it drift").
#   storage-health.nix's shell polls anticipated this exact replacement.
#
# Importing IS enabling. Every long-lived homelab host (andromeda, ursa, draco)
# imports this so draco's Prometheus can scrape it at <host>:9100.
#
# Retire when: a different metrics agent (e.g. Alloy / OpenTelemetry) is adopted.
{ ... }:
{
  flake.modules.nixos.node-exporter = { lib, ... }: {
    services.prometheus.exporters.node = {
      enable = true;
      port = 9100;
      # Defaults already cover cpu/meminfo/filesystem/diskstats/netdev/zfs;
      # add unit-state + process metrics (cheap, useful for the homelab).
      enabledCollectors = [ "systemd" "processes" ];
    };
    # Scraped by draco's Prometheus over the trusted LAN. The exporter exposes
    # only read-only host metrics; acceptable on the internal LAN. (A per-source
    # restriction to draco's IP is a possible hardening follow-up.)
    networking.firewall.allowedTCPPorts = [ 9100 ];
  };
}
