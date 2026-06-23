# Azure CLI + related cloud tooling for working with internal Azure
# resources (Synapse, ADLS Gen2 / blob storage, AAD-authenticated
# services).
#
# User-scoped: `az login` caches the token cache + profile under
# ~/.azure, and azcopy reads AAD/SAS credentials from the user session,
# so these belong in home-manager rather than environment.systemPackages.
#
# Members:
#   - azure-cli              `az` — the core CLI: ARM management, AAD
#                            tokens (`az account get-access-token
#                            --resource https://database.windows.net/`
#                            for Synapse, etc.), storage, and the
#                            **synapse** command group (`az synapse …`),
#                            which is built into core azure-cli — no
#                            extension needed — so it's pinned
#                            reproducibly by the azure-cli version in
#                            the flake lock. Optional third-party
#                            extensions can be baked in declaratively
#                            with `azure-cli.withExtensions [ … ]`.
#   - azure-storage-azcopy   `azcopy` — high-throughput copy/sync for
#                            Blob storage and ADLS Gen2 (datalake pulls).
#   - azure-storage-azcopy   `azcopy` — high-throughput copy/sync for
#                            Blob storage and ADLS Gen2 (datalake pulls).
#
# Situational tools intentionally left out of the default (import-and-
# add per host if needed): kubelogin (AKS AAD auth), bicep (IaC),
# sqlcmd (ad-hoc Synapse / Azure SQL queries).
#
# Pattern A: hosts opt in by importing. Currently the WSL hosts — the
# dev environments used against internal Azure resources. Any other host
# that needs Azure access can import it too.
#
# Retire when: the workflow no longer touches Azure, OR these tools move
#   into per-project devShells instead of the user profile.
{ ... }:
{
  flake.modules.homeManager.azure = { pkgs, ... }: {
    home.packages = with pkgs; [
      # az — `az synapse …` is core, so pinning this version pins
      # Synapse CLI support too.
      azure-cli
      azure-storage-azcopy
      # sqlcmd (go-sqlcmd) — query Synapse / Azure SQL endpoints
      # (e.g. indexquality-ondemand.sql.azuresynapse.net) with an AAD
      # token from `az account get-access-token`.
      sqlcmd
    ];
  };
}
