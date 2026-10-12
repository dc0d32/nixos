# Install the pinned WezTerm trial beside other terminals, without defaults.
# Retire when the trial is over or native Windows Nix can manage this package.
# Run explicitly: hm_win --terminals (WSL), or & '<deployed>/wezterm-install.ps1'.
# Windows x64 only: the upstream archive does not provide an ARM64 binary.
# Font prerequisite: run normal hm_win once to register patched Fantasque.
# No PATH changes, package-manager installs, default-terminal registration,
# renderer overrides, or automatic upgrades. All scratch stays in build dirs.
# BOOTSTRAP manifests refer to deletable upstream assets, not promoted releases.
# A future retained release uses assetStatus=promoted with its pinned URL/hash.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This installer requires native Windows.'
}
$nativeArchitecture = $env:PROCESSOR_ARCHITEW6432
if (-not $nativeArchitecture) { $nativeArchitecture = $env:PROCESSOR_ARCHITECTURE }
if ($nativeArchitecture -ne 'AMD64') {
    throw "WezTerm Trial supports verified Windows x64 binaries only (detected $nativeArchitecture)."
}

$pin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'wezterm-pin.json') -Raw | ConvertFrom-Json
if ($pin.version -notmatch '^[0-9]{8}-[0-9]{6}-[0-9a-f]+$' -or
    $pin.archiveRoot -ne "WezTerm-windows-$($pin.version)" -or
    $pin.sha256 -notmatch '^[0-9a-f]{64}$' -or
    $pin.revision -notmatch '^[0-9a-f]{40}$' -or
    $pin.url -notmatch '^https://[^/\s]+/\S+$' -or
    $pin.assetStatus -cnotin @('bootstrap-unpromoted', 'promoted') -or
    @($pin.architectures).Count -ne 1 -or $pin.architectures[0] -ne 'x86_64') {
    throw 'Invalid WezTerm provenance manifest.'
}
if ($pin.assetStatus -eq 'bootstrap-unpromoted') {
    Write-Warning 'BOOTSTRAP/unpromoted WezTerm asset: upstream may delete it. This explicit install can fail; ordinary hm_win never downloads it. Promote a retained URL/hash in the shared pin for durable installation.'
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
$buildId = "$($pin.version)-$($pin.sha256)"
$installDir = Join-Path $localAppData "nixwin\wezterm-trial\$buildId"
$exeDir = Join-Path $installDir $pin.archiveRoot
$exe = Join-Path $exeDir 'wezterm-gui.exe'
$marker = Join-Path $installDir 'installed-sha256.txt'
if (Test-Path -LiteralPath $installDir) {
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or
        (Get-Content -LiteralPath $marker -Raw).Trim() -ne $pin.sha256 -or
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
        if ($pin.headers) {
            foreach ($header in $pin.headers.PSObject.Properties) {
                $headers[$header.Name] = [string]$header.Value
            }
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try {
            Invoke-WebRequest -Uri $pin.url -Headers $headers -UserAgent 'nixwin-wezterm-trial' -OutFile $archive -UseBasicParsing
        } catch {
            throw "Pinned $($pin.assetStatus) archive unavailable: $($pin.url). No floating nightly fallback is allowed. If upstream deleted this bootstrap asset, promote a retained URL/hash in overlays/wezterm-pin.nix and redeploy. $($_.Exception.Message)"
        }
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $pin.sha256) {
            throw 'WezTerm archive SHA-256 mismatch; nothing installed.'
        }
        # .NET extracts directly here: no Expand-Archive/module scratch in TEMP.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, $attemptDir)
        $attemptExe = Join-Path (Join-Path $attemptDir $pin.archiveRoot) 'wezterm-gui.exe'
        if (-not (Test-Path -LiteralPath $attemptExe -PathType Leaf)) {
            throw "Expected executable absent: $attemptExe"
        }
        Remove-Item -LiteralPath $archive
        Set-Content -LiteralPath (Join-Path $attemptDir 'installed-sha256.txt') -Value $pin.sha256 -Encoding ASCII
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
    $description = "WezTerm Trial $buildId ($($pin.assetStatus), explicit install)"
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
