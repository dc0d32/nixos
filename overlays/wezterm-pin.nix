# Shared WezTerm provenance for Unix packages and the Windows bundle consumer.
# Retire when all consumers can use an equally recent, immutable upstream release.
# Import this data directly; it is not an overlay or a flake-parts module.
{
  revision = "e2a98e1b8af156988ad0ac778658ac27b60a55fb";
  commitDate = "2026-10-10T07:39:11Z";
  version = "20261010-073911-e2a98e1b";

  sourceHash = "sha256-8jRfyP39boYVxDYJush0Rc9EFwDvRL75gTMLliihTU8=";
  cargoHash = "sha256-GiHuJkkcPKoQpzVKDlbI2eZVj+5Fns/CHKxRtBw39WU=";

  # Windows-only bootstrap/unpromoted asset, pending a source-built Windows package.
  # Ordinary hm_win must not fetch this archive; only explicit trial installation may.
  # The immutable API asset ID fails closed on deletion and requires this header.
  assets = {
    windows = {
      status = "promoted";
      assetId = 632211026;
      url = "https://api.github.com/repos/dc0d32/wezterm-builds/releases/assets/632211026";
      headers = { Accept = "application/octet-stream"; };
      hash = "sha256-pukFd4ln6Wh2m3sxoNqh3IS04qzVsgVogyyWRnCnJjA=";
      sha256 = "a6e905778967e968769b7b31a0daa1dc84b4e2acd5b20568832c964670a72630";
      size = 72655831;
      archiveRoot = "WezTerm-windows-20261010-073911-e2a98e1b";
      architectures = [ "x86_64" ];
      sourceRevision = "e2a98e1b8af156988ad0ac778658ac27b60a55fb";
      buildRepository = "dc0d32/wezterm-builds";
      buildId = "e2a98e1b8af156988ad0ac778658ac27b60a55fb-38186846487-1";
      releaseTag = "wezterm-e2a98e1b8af156988ad0ac778658ac27b60a55fb-38186846487-1";
      runId = 38186846487;
      runAttempt = 1;
    };
  };
}
