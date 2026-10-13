# Install the pinned WezTerm trial beside other terminals, without defaults.
# Retire when the trial is over or native Windows Nix can manage this package.
# Run by hm_win --setup (WSL), or explicitly as & '<deployed>/wezterm-install.ps1'.
# Selects only the native x86-64 or ARM64 artifact; never uses x64 emulation.
# hm_win registers patched Fantasque before invoking this installer.
# No PATH changes, package-manager installs, default-terminal registration,
# renderer overrides, or automatic upgrades. All scratch stays in build dirs.
# BOOTSTRAP manifests refer to deletable upstream assets, not promoted releases.
# Promoted manifests use exact retained release URLs and pinned hashes, not REST downloads.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This installer requires native Windows.'
}
$nativeArchitecture = $env:PROCESSOR_ARCHITEW6432
if (-not $nativeArchitecture) { $nativeArchitecture = $env:PROCESSOR_ARCHITECTURE }
$architecture = switch ($nativeArchitecture) {
    'AMD64' { 'x86_64' }
    'ARM64' { 'aarch64' }
    default { throw "WezTerm Trial does not support native Windows architecture $nativeArchitecture." }
}

$pin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'wezterm-pin.json') -Raw | ConvertFrom-Json
$asset = $pin.assets.$architecture
if ($null -eq $asset) {
    throw "No native $architecture WezTerm pin is available. This bootstrap must not install x64 under emulation."
}
if ($pin.version -notmatch '^[0-9]{8}-[0-9]{6}-[0-9a-f]+$' -or
    $asset.architecture -cne $architecture -or
    $asset.archiveRoot -cnotmatch "^WezTerm-windows-(?:$architecture-)?$([regex]::Escape($pin.version))$" -or
    $asset.sha256 -notmatch '^[0-9a-f]{64}$' -or
    $pin.revision -notmatch '^[0-9a-f]{40}$' -or
    $asset.url -notmatch '^https://[^/\s]+/\S+$' -or
    $asset.assetStatus -cnotin @('bootstrap-unpromoted', 'promoted')) {
    throw 'Invalid WezTerm provenance manifest.'
}
$expectedRoot = if ($architecture -eq 'x86_64') {
    "WezTerm-windows-$($pin.version)"
} else {
    "WezTerm-windows-$architecture-$($pin.version)"
}
if ($asset.assetStatus -eq 'bootstrap-unpromoted') {
    if ($architecture -ne 'x86_64' -or
        $asset.archiveRoot -ne $expectedRoot) {
        throw 'Only the legacy x86_64 bootstrap asset may be unpromoted.'
    }
    Write-Warning 'BOOTSTRAP/unpromoted WezTerm asset: upstream may delete it. This explicit install can fail; ordinary hm_win never downloads it. Promote a retained URL/hash in the shared pin for durable installation.'
} elseif ($asset.archiveRoot -ne $expectedRoot) {
    throw 'Promoted WezTerm archive root does not match its native architecture.'
}
$configSource = Join-Path $PSScriptRoot 'wezterm.lua'
if (-not (Test-Path -LiteralPath $configSource -PathType Leaf)) {
    throw 'The bundled shared wezterm.lua is missing.'
}

function Backup-File([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        Copy-Item -LiteralPath $Path -Destination "$Path.bak.$(Get-Date -Format yyyyMMddHHmmssfffffff)"
    }
}

$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
$userProfile = [Environment]::GetFolderPath('UserProfile')
$programs = [Environment]::GetFolderPath('Programs')
foreach ($folder in @($localAppData, $userProfile, $programs)) {
    if ([string]::IsNullOrWhiteSpace($folder) -or -not [IO.Path]::IsPathRooted($folder)) {
        throw 'Windows user folders could not be resolved; nothing installed.'
    }
}
$buildId = "$architecture-$($pin.version)-$($asset.sha256)"
$installDir = Join-Path $localAppData "nixwin\wezterm-trial\$architecture\$($pin.version)-$($asset.sha256)"
$exeDir = Join-Path $installDir $asset.archiveRoot
$exe = Join-Path $exeDir 'wezterm-gui.exe'
$marker = Join-Path $installDir 'installed-provenance.txt'
$markerValue = "$architecture $($asset.sha256)"
if (Test-Path -LiteralPath $installDir) {
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or
        (Get-Content -LiteralPath $marker -Raw).Trim() -ne $markerValue -or
        -not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "Incomplete or conflicting install at $installDir. Preserve/remove it manually before retrying; it will not be overwritten."
    }
} else {
    # Same-source rebuilds have different archive hashes. Each retry gets a
    # distinct staging directory, so neither it nor a running build is clobbered.
    $attemptDir = "$installDir.attempt.$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $attemptDir | Out-Null
    try {
        $archive = Join-Path $attemptDir 'wezterm.zip'
        $headers = @{}
        if ($asset.headers) {
            foreach ($header in $asset.headers.PSObject.Properties) {
                $headers[$header.Name] = [string]$header.Value
            }
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try {
            Invoke-WebRequest -Uri $asset.url -Headers $headers -UserAgent 'nixwin-wezterm-trial' -OutFile $archive -UseBasicParsing
        } catch {
            throw "Pinned $($asset.assetStatus) $architecture archive unavailable: $($asset.url). No floating nightly or emulated-architecture fallback is allowed. Check connectivity and the exact pinned release; bootstrap assets may need replacement in overlays/wezterm-pin.nix. $($_.Exception.Message)"
        }
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $asset.sha256) {
            throw 'WezTerm archive SHA-256 mismatch; nothing installed.'
        }
        # .NET extracts directly here: no Expand-Archive/module scratch in TEMP.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, $attemptDir)
        $attemptExe = Join-Path (Join-Path $attemptDir $asset.archiveRoot) 'wezterm-gui.exe'
        if (-not (Test-Path -LiteralPath $attemptExe -PathType Leaf)) {
            throw "Expected executable absent: $attemptExe"
        }
        Remove-Item -LiteralPath $archive
        Set-Content -LiteralPath (Join-Path $attemptDir 'installed-provenance.txt') -Value $markerValue -Encoding ASCII
        if (Test-Path -LiteralPath $installDir) {
            throw "Another install created $installDir; it will not be overwritten."
        }
        [IO.Directory]::Move($attemptDir, $installDir)
    } catch {
        throw "Install failed; retained $attemptDir for inspection. Retrying uses a new attempt directory; completed builds are never overwritten. $($_.Exception.Message)"
    }
}

$configDir = Join-Path $userProfile '.config\nixwin\wezterm-trial\config'
New-Item -ItemType Directory -Path $configDir -Force | Out-Null
$configTarget = Join-Path $configDir 'wezterm.lua'
if (-not (Test-Path -LiteralPath $configTarget -PathType Leaf) -or
    (Get-FileHash -LiteralPath $configTarget).Hash -ne (Get-FileHash -LiteralPath $configSource).Hash) {
    Backup-File $configTarget
    Copy-Item -LiteralPath $configSource -Destination $configTarget -Force
}

$shortcutPath = Join-Path $programs 'WezTerm Trial.lnk'
New-Item -ItemType Directory -Path $programs -Force | Out-Null
$shell = New-Object -ComObject WScript.Shell
$shortcut = $null
try {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $arguments = "--config-file `"$configTarget`""
    $description = "WezTerm Trial $buildId ($($asset.assetStatus), explicit install)"
    if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf) -or
        $shortcut.TargetPath -ne $exe -or $shortcut.Arguments -ne $arguments -or
        $shortcut.WorkingDirectory -ne $userProfile -or
        $shortcut.IconLocation -ne "$exe,0" -or $shortcut.Description -ne $description) {
        Backup-File $shortcutPath
        $shortcut.TargetPath = $exe
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = $userProfile
        $shortcut.IconLocation = "$exe,0"
        $shortcut.Description = $description
        $shortcut.Save()
    }
} finally {
    if ($shortcut) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
}
Write-Host "Installed WezTerm Trial $($pin.version): $exe"
Write-Host 'Launch from Start: WezTerm Trial. Windows Terminal and other installations are unchanged.'
Write-Host 'Font prerequisite: normal hm_win must have registered the patched Fantasque font once.'
