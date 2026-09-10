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
    The executable Velopack points --mainExe at is OpenPairings.exe, built
    from rel/windows/launcher.c by the release step in mix.exs. So the payload
    this wants is a portable release produced by `mix release
    pairings_engine_portable` on a machine with Zig, or the
    openpairings_portable_windows_x86_64 artifact from binaries.yml, which is
    built the same way.

    WHY THE PACK ID IS NOT "OpenPairings": it would have deleted the
    database.

    Velopack installs a per-user app to %LOCALAPPDATA%\<packId>, and
    UNINSTALLING deletes that whole directory - not only the files it put
    there. Verified on 2026-09-10 by packing this same payload under a
    throwaway packId, installing it, dropping an openpairings.db and a
    backups\ folder into the install root by hand, and uninstalling: both were
    gone, and the directory with them.

    With `--packId OpenPairings` below, that directory is
    %LOCALAPPDATA%\OpenPairings, which is exactly where a local run keeps
    `openpairings.db`, `secret_key_base` and `backups\` (config/runtime.exs,
    via :filename.basedir). So uninstalling OpenPairings would silently delete
    every tournament the arbiter has ever run.

    Two ways out, and the trade decided it:

      * Move the INSTALL root. One line, no migration, no change to the app -
        the cost is a pack id that is not the product's name, and the pack id
        is also the update feed's id, so it is awkward to change after
        anything ships.
      * Move the DATA directory. Tidier, and far more expensive: every
        existing local installation already has its tournaments at the old
        path, so it needs a migration that cannot be allowed to fail.

    The install root moved, because the cost of getting it wrong is not
    symmetric. A pack id nobody looks at is a cosmetic problem; a migration
    that misfires is somebody's tournament. Chosen NOW rather than later
    precisely because the id is awkward to change once a release exists, and
    none does yet.

    The installer is renamed back to OpenPairings-win-Setup.exe afterwards.
    That filename appears nowhere in the update feed - the updater reads
    releases.win.json and fetches .nupkg files - so it is a label on the
    download and nothing more.

    `Assert-DataDirectorySafe` below enforces this. It is not decoration: the
    obvious future edit is somebody tidying the pack id back to the product's
    name, which would silently arm the same deletion again.
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

    [string]$OutputDir = "$PSScriptRoot\..\..\burrito_out\installer",

    # Same meaning as `mix release --overwrite`, and needed for the same
    # reason: `vpk` refuses to pack when the output directory already holds a
    # release with this version or a newer one, which is correct for a real
    # update feed and pure friction while you are iterating on the packaging.
    [switch]$Overwrite
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

# A hard stop, not a warning. Velopack will happily pack a payload whose
# --mainExe is absent and hand you a Setup.exe that installs an application
# nothing can start - which is worse than no installer at all, because it looks
# like one that works until somebody clicks the shortcut.
if (-not (Test-Path (Join-Path $PayloadDir 'OpenPairings.exe'))) {
    throw @"
No OpenPairings.exe in $PayloadDir.

Velopack's --mainExe must exist in the package root. The release step in
mix.exs puts it there; it skips itself when Zig is not on PATH, which is the
usual reason it is missing. Install Zig and rebuild:

    MIX_ENV=prod mix release pairings_engine_portable --overwrite
"@
}

# `vpk` treats the output directory as an update feed and refuses to pack a
# version that is already in it - and says so on stderr, where a `throw` two
# lines later can bury it. Deal with it here, where the message can say what
# to do about it.
if (Test-Path $OutputDir) {
    $existing = @(Get-ChildItem $OutputDir -Filter "*$Version*.nupkg" -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        if (-not $Overwrite) {
            throw "$OutputDir already holds a $Version package. Bump the version, or pass -Overwrite."
        }
        Write-Host "Removing the previous $Version build from $OutputDir" -ForegroundColor DarkGray
        Remove-Item "$OutputDir\*" -Recurse -Force
    }
}

# NOT the product name - see .NOTES. Velopack installs a per-user app to
# %LOCALAPPDATA%\<packId> and its uninstaller deletes that directory whole,
# so this must never equal the folder `:filename.basedir(:user_data, ...)`
# hands the application.
$packId = 'OpenPairingsApp'

function Assert-DataDirectorySafe {
    param([string]$Id)

    # The app's own data directory, resolved the same way config/runtime.exs
    # resolves it: Erlang's :filename.basedir(:user_data, "OpenPairings"),
    # which on Windows is %LOCALAPPDATA%\OpenPairings.
    $dataDir = Join-Path $env:LOCALAPPDATA 'OpenPairings'
    $installDir = Join-Path $env:LOCALAPPDATA $Id

    if ($installDir -eq $dataDir) {
        throw @"
Refusing to pack: the install directory would be the data directory.

  pack id     : $Id
  installs to : $installDir
  database at : $dataDir

Velopack's uninstaller deletes its install directory whole. Packing this
would produce an installer whose uninstall silently destroys every
tournament on the machine. See .NOTES in this script.
"@
    }
}

Assert-DataDirectorySafe -Id $packId

Write-Host "Packing OpenPairings $Version from $PayloadDir" -ForegroundColor Cyan

# --shortcuts: Desktop AND StartMenu, because the audience is arbiters who
# are not comfortable hunting through Program Files. Per-user install is
# Velopack's default (%LOCALAPPDATA%), which also means no UAC prompt and no
# admin rights - the latter matters on federation-managed laptops.
& vpk pack `
    --packId $packId `
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

# Back to the product's name. Only the download's label changes; the feed
# and the packages inside keep the pack id.
$built = Join-Path $OutputDir "$packId-win-Setup.exe"
$wanted = Join-Path $OutputDir 'OpenPairings-win-Setup.exe'

if (Test-Path $built) {
    Move-Item -Path $built -Destination $wanted -Force
}

Write-Host "`nInstaller written to $OutputDir" -ForegroundColor Green
Get-ChildItem $OutputDir -Filter '*Setup.exe' |
    Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } } |
    Format-Table -AutoSize
