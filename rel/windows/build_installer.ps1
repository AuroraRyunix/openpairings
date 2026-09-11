<#
.SYNOPSIS
    Packs the Windows installers, branded, from the portable release.

.DESCRIPTION
    Velopack (`vpk`) wraps the portable release into two installers -
    Setup.exe (one-click, per-user only) and a .msi (a real wizard, with a
    per-user/per-machine choice) - plus the update feed they and a future
    in-app updater read from. This script exists so the branding arguments
    live somewhere version-controlled rather than in somebody's shell
    history.

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

    `Assert-DataDirectorySafe` below enforces this, for both install roots
    Velopack can produce - see "PER-MACHINE AND THE DATA DIRECTORY" further
    down. It is not decoration: the obvious future edit is somebody tidying
    the pack id back to the product's name, which would silently arm the
    same deletion again.

    THE WIZARD, AND WHAT IT DOES NOT DO TO Setup.exe:

    --instWelcome, --instLicense, --instConclusion and --instLocation are
    passed to `vpk pack` below because they were asked for, they are
    harmless, and the content they point at is real. What they are NOT is a
    fix for "Setup.exe never asks anything" - checked against Velopack's own
    docs (docs.velopack.io/packaging/installer, read 2026-09-11) and then
    empirically, by packing a throwaway payload twice, once with these four
    flags and once without, and diffing the two Setup.exe files byte for
    byte: they came out 7 bytes apart (the pack id string, nothing else) and
    neither contained a trace of the welcome/licence/conclusion text.

    The docs say why: "The Windows installer is currently a 'one-click'
    installer, meaning when the Setup.exe binary is run, Velopack will not
    show any questions / wizards to the user." That is not conditional on
    which flags are set - it is what Setup.exe is. --instWelcome and its
    three siblings are consumed by a *different* installer artifact, a WiX
    .msi, which is what --msi below builds, and which is the file the wizard
    content, --instLocation, --msiBanner and --msiLogo all actually reach.
    OpenPairings-win-Setup.exe stays a silent one-click installer regardless
    - that is Velopack's design, not a gap in this script - and remains
    beside the .msi as the one-click alternative. See docs/binaries.md for
    which one the release page actually points people at.

    The .msi is renamed OpenPairings-win-Setup.msi below, the same way the
    Setup.exe is - see the rename block near the bottom.

    Verifying the .msi without installing it: per-machine needs admin, and
    even per-user would install software on whoever runs this script.
    Instead, inspected offline with the Windows Installer COM API
    (`New-Object -ComObject WindowsInstaller.Installer`, built into Windows -
    no extra tool needed), which opens a .msi as a database and lets its
    tables be queried with MSI's own SQL dialect. That is how everything in
    "PER-MACHINE AND THE DATA DIRECTORY" below was established: not read off
    Velopack's docs (which turn out to describe something else - see below),
    but read out of the actual Property, Directory and ControlEvent tables of
    a .msi this script built.

    PER-MACHINE AND THE DATA DIRECTORY:

    --instLocation governs the .msi only; Setup.exe has no install-location
    choice to give, ever - see above. `PerUser` installs to
    %LOCALAPPDATA%\<packId>, the root Setup.exe already uses unconditionally.
    `PerMachine` installs to Program Files (HKLM, needs elevation). `Either`,
    passed below, lets whoever runs the .msi choose, in the .msi's own UI.

    Velopack's own docs (docs.velopack.io/packaging/installer, read
    2026-09-11) say PerMachine "installs to Program Files\{publisher}\
    {packTitle}". THAT IS NOT WHAT THIS SCRIPT'S .msi DOES, verified by
    querying a .msi it actually built (vpk 1.2.0) rather than trusting the
    prose: the MSI's Property table has `ApplicationFolderName` set to the
    *pack id*, not the title, and its ControlEvent table sets INSTALLFOLDER
    to `[LocalAppDataFolder][ApplicationFolderName]` for a per-user choice
    and `[ProgramFiles64Folder][ApplicationFolderName]` for a per-machine
    one - one path segment either way, never nested under a publisher folder.
    With $packId below that is Program Files\OpenPairingsApp: the exact same
    single-segment name Setup.exe already uses under %LOCALAPPDATA%, just
    under a different root. (Whether this is a version difference from
    whatever the docs describe, or the docs are simply wrong, was not worth
    chasing further - what matters here is what THIS script's .msi actually
    installs, and now it is verified rather than assumed.)

    Program Files\OpenPairingsApp is a different filesystem root from
    %LOCALAPPDATA%\OpenPairings entirely, so - like the per-user pack id - it
    cannot collide with the data directory: there is no install root under
    Program Files that :filename.basedir(:user_data, ...) would ever resolve
    to. Assert-DataDirectorySafe below asserts this anyway, rather than
    leaving it as a comment for the next person to re-derive, because the
    day somebody "tidies" $packId back to the product's name is exactly the
    day they are not thinking about this guard.

    Uninstalling is not plain MSI component removal either, for either
    scope: the .msi's CustomAction table carries Velopack's own
    RustCleanup/UninstallHookDeferred actions, the same mechanism Setup.exe's
    uninstaller uses to delete its install directory whole rather than only
    the files it tracked (verified for Setup.exe on 2026-09-10 by dropping an
    openpairings.db and a backups\ folder into a throwaway install root by
    hand and watching uninstall take them with it). The pack-id-not-product-
    name guard above is what stops that whole-directory delete from ever
    being able to reach the data directory, on either install path.

    The data directory itself does not move with the install root, in either
    case. config/runtime.exs and rel/windows/launcher.c both resolve it from
    %LOCALAPPDATA%, which Windows always resolves to whichever account is
    running the process - a property of the user, not of where
    OpenPairings.exe happens to sit on disk. So a machine-wide install shares
    one copy of the *program* across every Windows account on the machine,
    and still gives each of them their own database: two arbiters sharing a
    library PC would not see each other's tournaments. That is worth knowing
    before anyone recommends a shared install as a way to get a shared
    database, which it is not. See docs/binaries.md.

    CAN A PER-MACHINE INSTALL UPDATE ITSELF WITHOUT ADMIN? No, and this
    matters enough to say plainly rather than bury it: Velopack's own docs
    state "updates work identically via Update.exe regardless of whether the
    app was installed with Setup.exe or the .msi" - and a per-machine install
    puts Update.exe, like everything else, under Program Files, which an
    ordinary user process cannot write to without elevation. A per-machine
    install can only update by prompting for admin every time, same as it
    needed admin to install. Per-user has no such problem - %LOCALAPPDATA% is
    always writable by its own owner - which is the other reason Setup.exe's
    per-user install stays the default this project actually recommends;
    per-machine exists in the .msi because the maintainer asked for it, not
    because it is the better path for an arbiter's own laptop.
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

    # No default here - see below. $PSScriptRoot is not reliably populated
    # yet while a top-level script's parameter defaults are being evaluated
    # (reproduced locally: it is empty at this point and only set once the
    # script body starts), so a default expressed here silently resolves to
    # a bare "\..\..\burrito_out\installer" - drive-root-relative, and one
    # ".." past the root of whichever drive is current fails outright, which
    # is exactly the "referred to an item that was outside the base 'C:'"
    # this would otherwise throw on every run that does not pass -OutputDir.
    [string]$OutputDir,

    # Same meaning as `mix release --overwrite`, and needed for the same
    # reason: `vpk` refuses to pack when the output directory already holds a
    # release with this version or a newer one, which is correct for a real
    # update feed and pure friction while you are iterating on the packaging.
    [switch]$Overwrite
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is reliable from here on - see the -OutputDir param comment.
if (-not $OutputDir) {
    $OutputDir = "$PSScriptRoot\..\..\burrito_out\installer"
}

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
$msiBanner = Join-Path $PSScriptRoot 'msi_banner.bmp'
$msiLogo = Join-Path $PSScriptRoot 'msi_logo.bmp'

foreach ($asset in @($icon, $splash, $msiBanner, $msiLogo)) {
    if (-not (Test-Path $asset)) {
        throw "Missing $asset - run: py -3 rel/windows/build_brand_assets.py"
    }
}

# Wizard content for the pages listed in .NOTES. Welcome and Conclusion are
# hand-written and versioned normally; Licence is derived below rather than
# hand-copied, so it can never say something LICENSE itself does not.
$installerContentDir = Join-Path $PSScriptRoot 'installer-content'
$welcome = Join-Path $installerContentDir 'welcome.md'
$conclusion = Join-Path $installerContentDir 'conclusion.md'

foreach ($asset in @($welcome, $conclusion)) {
    if (-not (Test-Path $asset)) {
        throw "Missing $asset - these are hand-written, not generated. Restore them from version control."
    }
}

# `vpk` picks a renderer by file extension (.txt, .md, or .rtf) and the
# repository's LICENSE has none, so it would not be recognised as either.
# Copied rather than rewritten - the licence text must not be paraphrased or
# summarised - and copied on every build rather than checked in as a second
# file, so it can never drift from LICENSE. Gitignored; see
# rel/windows/.gitignore.
$licenseSrc = Join-Path $PSScriptRoot '..\..\LICENSE'
$license = Join-Path $installerContentDir 'LICENSE.md'
Copy-Item -Path $licenseSrc -Destination $license -Force

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
# %LOCALAPPDATA%\<packId>, and a per-machine one (the .msi) to
# Program Files\<packId> - same single segment, different root - and its
# uninstaller deletes that directory whole, so this must never equal the
# folder `:filename.basedir(:user_data, ...)` hands the application.
# $packAuthors/$packTitle are cosmetic: the display name in the wizard, the
# Start Menu folder, and Add/Remove Programs - not part of either install
# root (verified against the .msi's own tables - see .NOTES).
$packId = 'OpenPairingsApp'
$packAuthors = 'OpenPairings'
$packTitle = 'OpenPairings'

function Assert-DataDirectorySafe {
    param([hashtable]$InstallRoots)

    # The app's own data directory, resolved the same way config/runtime.exs
    # and rel/windows/launcher.c both resolve it: Erlang's
    # :filename.basedir(:user_data, "OpenPairings"), which on Windows is
    # %LOCALAPPDATA%\OpenPairings. Neither of those reads anything about
    # where the program itself is installed - a machine-wide install does
    # not change this path, it only changes who is running the process that
    # resolves it. See .NOTES.
    $dataDir = Join-Path $env:LOCALAPPDATA 'OpenPairings'

    foreach ($label in $InstallRoots.Keys) {
        $installDir = $InstallRoots[$label]
        if ($installDir -eq $dataDir) {
            throw @"
Refusing to pack: the $label install directory would be the data directory.

  install root ($label): $installDir
  database at           : $dataDir

Velopack's uninstaller deletes its install directory whole. Packing this
would produce an installer whose uninstall silently destroys every
tournament on the machine. See .NOTES in this script.
"@
        }
    }
}

# Two roots, both real: the per-user root Setup.exe and a per-user .msi both
# use, and the per-machine root a per-machine .msi uses. Both are a single
# <packId> segment under a different base folder - confirmed by querying the
# Property and ControlEvent tables of a .msi this script actually built, not
# assumed from Velopack's docs, which describe a different (nested) path for
# PerMachine - see "PER-MACHINE AND THE DATA DIRECTORY" in .NOTES.
Assert-DataDirectorySafe -InstallRoots @{
    'per-user (Setup.exe or the .msi)' = Join-Path $env:LOCALAPPDATA $packId
    'per-machine (the .msi)'           = Join-Path $env:ProgramFiles $packId
}

Write-Host "Packing OpenPairings $Version from $PayloadDir" -ForegroundColor Cyan

# --shortcuts: Desktop AND StartMenu, because the audience is arbiters who
# are not comfortable hunting through Program Files. Per-user install is
# Velopack's default (%LOCALAPPDATA%) for Setup.exe unconditionally - no UAC
# prompt, no admin rights, which matters on federation-managed laptops - and
# --instLocation below does not change that: it governs only the .msi (see
# .NOTES), where Either genuinely offers a per-user/per-machine choice in the
# .msi's own UI, defaulting the radio to per-machine (Velopack's own choice,
# not this script's - see the InstallScopeDlg dump behind "PER-MACHINE AND
# THE DATA DIRECTORY" in .NOTES if that default ever needs re-checking).
#
# No --instReadme: Welcome, Licence and Conclusion between them already say
# what the program is, what the licence permits, and where the data lives -
# a fourth page repeating some of that is a click an arbiter gains nothing
# from.
#
# --msiBanner/--msiLogo: WiX "Bitmap" dialog controls, so both must be .bmp
# at the exact resolution vpk asks for - see rel/windows/build_brand_assets.py
# for why they are drawn (not converted) from the same mark as the icon and
# splash, and why the logo splits into a dark column and a light one instead
# of going full-bleed like the splash does.
& vpk pack `
    --packId $packId `
    --packVersion $Version `
    --packDir $PayloadDir `
    --mainExe OpenPairings.exe `
    --packTitle $packTitle `
    --packAuthors $packAuthors `
    --icon $icon `
    --splashImage $splash `
    --shortcuts 'Desktop,StartMenu' `
    --instWelcome $welcome `
    --instLicense $license `
    --instConclusion $conclusion `
    --instLocation Either `
    --msi `
    --msiBanner $msiBanner `
    --msiLogo $msiLogo `
    --outputDir $OutputDir

if ($LASTEXITCODE -ne 0) { throw "vpk pack failed with exit code $LASTEXITCODE" }

# Back to the product's name. Only the two human-facing downloads' labels
# change; the update feed (releases.win.json, RELEASES) and the .nupkg files
# inside keep the pack id - Velopack's updater resolves those by name, so
# renaming them would break every install already out there. Never rename
# those three.
$renames = @{
    "$packId-win-Setup.exe" = 'OpenPairings-win-Setup.exe'
    "$packId-win.msi"       = 'OpenPairings-win-Setup.msi'
}
foreach ($from in $renames.Keys) {
    $built = Join-Path $OutputDir $from
    if (Test-Path $built) {
        Move-Item -Path $built -Destination (Join-Path $OutputDir $renames[$from]) -Force
    }
}

# assets.win.json is vpk's own manifest of what it just built, written
# before the rename above - so left alone it would name two files that no
# longer exist on disk. Nothing in this repository reads it today, but
# shipping a manifest that lies about its own output is worse than not
# shipping one, so it is rewritten here rather than left stale or deleted.
$assetsManifest = Join-Path $OutputDir 'assets.win.json'
if (Test-Path $assetsManifest) {
    # NOT wrapped in @(...) - `@(Get-Content ... | ConvertFrom-Json)` nests
    # the whole parsed array as a single element instead of flattening it
    # (reproduced on Windows PowerShell 5.1: a 4-entry manifest came back as
    # Count=1, one "entry" whose RelativeFileName concatenated all four
    # filenames space-separated), where the same call without @(...) parses
    # correctly. Bare `ConvertFrom-Json` already returns Object[] for a
    # multi-element JSON array on both 5.1 and 7.x, which is all this
    # manifest ever contains - at least the .exe and the .nupkg.
    $assets = Get-Content $assetsManifest -Raw | ConvertFrom-Json
    foreach ($entry in $assets) {
        if ($renames.ContainsKey($entry.RelativeFileName)) {
            $entry.RelativeFileName = $renames[$entry.RelativeFileName]
        }
    }
    # -Compress to match vpk's own (unindented) formatting.
    $json = $assets | ConvertTo-Json -Compress
    Set-Content -Path $assetsManifest -Value $json -Encoding utf8 -NoNewline
}

Write-Host "`nInstaller written to $OutputDir" -ForegroundColor Green
Get-ChildItem $OutputDir -Include '*Setup.exe', '*Setup.msi' -File |
    Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } } |
    Format-Table -AutoSize
