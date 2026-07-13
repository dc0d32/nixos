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
  flake.modules.nixos.node-exporter = { lib, config, ... }:
    let
      cfg = config.homelab.nodeExporter;
    in
    {
      options.homelab.nodeExporter.allowedInterfaces = lib.mkOption {
        type = with lib.types; nullOr (listOf str);
        default = null;
        example = [ "vlan10" ];
        description = ''
          Interfaces on which the node exporter port (9100) is reachable.
          `null` (default) opens 9100 on every interface — backward compatible,
          but readable from any VLAN that can route to the host. A list scopes
          9100 to only those interfaces (e.g. the trusted VLAN the Prometheus
          scraper lives on), so host metrics are not exposed LAN/VLAN-wide. An
          empty list keeps 9100 fully firewalled (local 127.0.0.1 scrape only).
        '';
      };

      config = {
        services.prometheus.exporters.node = {
          enable = true;
          port = 9100;
          # Defaults already cover cpu/meminfo/filesystem/diskstats/netdev/zfs;
          # add unit-state + process metrics (cheap, useful for the homelab).
          enabledCollectors = [ "systemd" "processes" ];
        };
        # Exposes only read-only host metrics. Open globally by default; hosts
        # that set allowedInterfaces restrict it to the trusted scrape path.
        networking.firewall = lib.mkMerge [
          (lib.mkIf (cfg.allowedInterfaces == null) {
            allowedTCPPorts = [ 9100 ];
          })
          (lib.mkIf (cfg.allowedInterfaces != null) {
            interfaces =
              lib.genAttrs cfg.allowedInterfaces (_: { allowedTCPPorts = [ 9100 ]; });
          })
        ];
      };
    };
}
