<#
.SYNOPSIS
    Packs the Windows installer, branded, from the portable release.

.DESCRIPTION
    Velopack (`vpk`) wraps the portable release into a per-user installer plus
    an update feed. This script exists so the branding arguments live
    somewhere version-controlled rather than in somebody's shell history.

    Why Velopack and not a single self-extracting binary: measured on
    2026-09-08 against Symantec Endpoint Protection on the maintainer's own
    machine, the Burrito single .exe is DELETED on execution (Heur.AdvML.D,
    a machine-learning heuristic) while both the portable release and an
    unsigned Velopack Setup.exe pass untouched. The federation's own SWAR
    ships an unsigned Inno Setup installer past the same scanner. So the
    deciding factor is packaging shape, not a code-signing certificate - a
    bespoke self-extracting stub is opaque and reads as a dropper, whereas
    scanners parse the common installer formats.

    That is not the whole story: SmartScreen is a separate system, and while
    a binary is unsigned its reputation attaches to the file hash and
    therefore resets on every release. Signing is what makes reputation
    attach to the certificate instead. Until then, expect the blue
    "Windows protected your PC" wall on first downloads.

.NOTES
    NOT FINISHED: the payload needs a real .exe at its root.

    Velopack's -e/--mainExe takes a FILE NAME and requires that executable to
    exist in the package root. The portable release's entry point is
    `OpenPairings.bat`, a launcher script, and there is no .exe. The
    2026-09-08 proof-of-concept used a copy of `erl.exe` as a stand-in, which
    packages and installs correctly but is not a launcher: it will not start
    the app. A small launcher executable is the remaining work before this
    ships to anyone.

    Everything else here - the icon, the splash, the shortcuts, the strings -
    is finished and correct.
#>

[CmdletBinding()]
param(
    # The portable release directory, e.g. the unpacked
    # openpairings_portable_windows_x86_64 artifact from binaries.yml.
    [Parameter(Mandatory = $true)]
    [string]$PayloadDir,

    # Defaults to the version in mix.exs, so the installer cannot drift from
    # the application it carries.
    [string]$Version,

    [string]$OutputDir = "$PSScriptRoot\..\..\burrito_out\installer"
)

$ErrorActionPreference = 'Stop'

# Scoop installs the SDK outside the location the `vpk` apphost looks in, so
# without this it fails with "You must install .NET to run this application"
# even though `dotnet --version` works.
if (-not $env:DOTNET_ROOT) {
    $scoopSdk = "$env:USERPROFILE\scoop\apps\dotnet-sdk\current"
    if (Test-Path $scoopSdk) { $env:DOTNET_ROOT = $scoopSdk }
}
$env:Path = "$env:USERPROFILE\.dotnet\tools;$env:DOTNET_ROOT;$env:Path"

if (-not (Get-Command vpk -ErrorAction SilentlyContinue)) {
    throw "vpk not found. Install it with: dotnet tool install -g vpk"
}

if (-not $Version) {
    $mixExs = Join-Path $PSScriptRoot '..\..\mix.exs'
    $match = Select-String -Path $mixExs -Pattern 'version:\s*"([0-9]+\.[0-9]+\.[0-9]+)"' |
        Select-Object -First 1
    if (-not $match) { throw "Could not read the version from mix.exs; pass -Version." }
    $Version = $match.Matches[0].Groups[1].Value
}

$icon = Join-Path $PSScriptRoot 'OpenPairings.ico'
$splash = Join-Path $PSScriptRoot 'splash.png'

foreach ($asset in @($icon, $splash)) {
    if (-not (Test-Path $asset)) {
        throw "Missing $asset - run: py -3 rel/windows/build_brand_assets.py"
    }
}

if (-not (Test-Path (Join-Path $PayloadDir 'OpenPairings.exe'))) {
    Write-Warning @'
No OpenPairings.exe in the payload root.

Velopack needs a real executable there and the portable release ships
OpenPairings.bat instead. The pack below will fail, or produce an installer
that installs an app it cannot start. See the NOTES in this script.
'@
}

Write-Host "Packing OpenPairings $Version from $PayloadDir" -ForegroundColor Cyan

# --shortcuts: Desktop AND StartMenu, because the audience is arbiters who
# are not comfortable hunting through Program Files. Per-user install is
# Velopack's default (%LOCALAPPDATA%), which also means no UAC prompt and no
# admin rights - the latter matters on federation-managed laptops.
& vpk pack `
    --packId OpenPairings `
    --packVersion $Version `
    --packDir $PayloadDir `
    --mainExe OpenPairings.exe `
    --packTitle 'OpenPairings' `
    --packAuthors 'OpenPairings' `
    --icon $icon `
    --splashImage $splash `
    --shortcuts 'Desktop,StartMenu' `
    --outputDir $OutputDir

if ($LASTEXITCODE -ne 0) { throw "vpk pack failed with exit code $LASTEXITCODE" }

Write-Host "`nInstaller written to $OutputDir" -ForegroundColor Green
Get-ChildItem $OutputDir -Filter '*Setup.exe' |
    Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } } |
    Format-Table -AutoSize
