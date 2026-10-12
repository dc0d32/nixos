# Shared WezTerm provenance for Unix packages and the Windows bundle consumer.
# Retire when all consumers can use an equally recent, immutable upstream release.
# Import this data directly; it is not an overlay or a flake-parts module.
{
  revision = "e2a98e1b8af156988ad0ac778658ac27b60a55fb";
  commitDate = "2026-10-10T07:39:11Z";
  version = "20261010-083911-e2a98e1b";

  sourceHash = "sha256-8jRfyP39boYVxDYJush0Rc9EFwDvRL75gTMLliihTU8=";
  cargoHash = "sha256-GiHuJkkcPKoQpzVKDlbI2eZVj+5Fns/CHKxRtBw39WU=";

  # Windows-only bootstrap/unpromoted asset, pending a source-built Windows package.
  # Ordinary hm_win must not fetch this archive; only explicit trial installation may.
  # The immutable API asset ID fails closed on deletion and requires this header.
  assets = {
    windows = {
      x86_64 = {
        status = "bootstrap-unpromoted";
        assetId = 629718573;
        url = "https://api.github.com/repos/wezterm/wezterm/releases/assets/629718573";
        headers = { Accept = "application/octet-stream"; };
        hash = "sha256-p64K53qOcvRZFXyD+xVDU6txhZCNuulHVZtXtiQ4FRY=";
        sha256 = "a7ae0ae77a8e72f459157c83fb154353ab7185908dbae947559b57b624381516";
        size = 70865818;
        archiveRoot = "WezTerm-windows-20261010-083911-e2a98e1b";
        architecture = "x86_64";
      };
      # The first verified schema-2 promotion replaces this with a native pin.
      aarch64 = null;
    };
  };
}
