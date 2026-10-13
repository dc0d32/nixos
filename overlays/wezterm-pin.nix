# Shared WezTerm provenance for Unix packages and the Windows bundle consumer.
# Retire when all consumers can use an equally recent, immutable upstream release.
# Import this data directly; it is not an overlay or a flake-parts module.
{
  revision = "e2a98e1b8af156988ad0ac778658ac27b60a55fb";
  commitDate = "2026-10-10T07:39:11Z";
  version = "20261010-073911-e2a98e1b";

  sourceHash = "sha256-8jRfyP39boYVxDYJush0Rc9EFwDvRL75gTMLliihTU8=";
  cargoHash = "sha256-GiHuJkkcPKoQpzVKDlbI2eZVj+5Fns/CHKxRtBw39WU=";

  # Retained immutable dual-architecture release, verified against its build run.
  # Ordinary hm_win only stages configuration; hm_win --setup installs the native pin.
  assets = {
    windows = {
      x86_64 = {
        status = "promoted";
        assetId = 635817801;
        url = "https://api.github.com/repos/dc0d32/wezterm-builds/releases/assets/635817801";
        headers = { Accept = "application/octet-stream"; };
        hash = "sha256-KP5tAlMbT8CHmkoY8aR5ADMtoHTifnUgDLiPXODVK/A=";
        sha256 = "28fe6d02531b4fc0879a4a18f1a47900332da074e27e75200cb88f5ce0d52bf0";
        size = 72644565;
        archiveRoot = "WezTerm-windows-20261010-073911-e2a98e1b";
        architecture = "x86_64";
        sourceRevision = "e2a98e1b8af156988ad0ac778658ac27b60a55fb";
        buildRepository = "dc0d32/wezterm-builds";
        buildId = "e2a98e1b8af156988ad0ac778658ac27b60a55fb-38340500959-1";
        releaseTag = "wezterm-e2a98e1b8af156988ad0ac778658ac27b60a55fb-38340500959-1";
        runId = 38340500959;
        runAttempt = 1;
      };
      aarch64 = {
        status = "promoted";
        assetId = 635817731;
        url = "https://api.github.com/repos/dc0d32/wezterm-builds/releases/assets/635817731";
        headers = { Accept = "application/octet-stream"; };
        hash = "sha256-y0u8WO8QkX2hiahLOQHZv0aYJFfzdH0mfbuFinUrr58=";
        sha256 = "cb4bbc58ef10917da189a84b3901d9bf46982457f3747d267dbb858a752baf9f";
        size = 53459454;
        archiveRoot = "WezTerm-windows-aarch64-20261010-073911-e2a98e1b";
        architecture = "aarch64";
        sourceRevision = "e2a98e1b8af156988ad0ac778658ac27b60a55fb";
        buildRepository = "dc0d32/wezterm-builds";
        buildId = "e2a98e1b8af156988ad0ac778658ac27b60a55fb-38340500959-1";
        releaseTag = "wezterm-e2a98e1b8af156988ad0ac778658ac27b60a55fb-38340500959-1";
        runId = 38340500959;
        runAttempt = 1;
      };
    };
  };
}
