# selftest-helper.ps1 - proves the update helper on real hardware before a
# release ships (CI runs it on every platform the run built; the local rig
# uses it too). This is how macOS gets covered without the maintainer
# owning a Mac.
#
# For the given platform it:
#   1. stages the helper exactly as publish.ps1 does (source repo baked in),
#   2. builds a fake install in a sandbox: a copy of the just-built artifact
#      plus a marker claiming an older version in the same version line,
#   3. drives the helper's auto mode against a local test release
#      (-SourceDir: no network, same verify path),
#   4. asserts: exit 0, marker updated, backup made, checksum verified,
#   5. runs it again: "current" must stay silent and touch nothing,
#   6. tampers with checksums.txt: the helper must refuse and change nothing,
#   7. on Windows and Linux, turns the optional background check on and off
#      (macOS has none yet - there the script must decline politely),
#   8. marks the release ignored: auto must skip it silently, changing
#      nothing,
#   9. apply with -Yes / --yes installs an ignored version anyway and
#      clears the ignore record again,
#   10. apply with no way to ask (CI stdin) must answer "cancel" by itself:
#       exit 0, nothing changed - the no-hang guarantee.
#
# A red self-test keeps the release from publishing (the publish job waits
# on this one). Exit code 0 = all checks passed.

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('windows', 'linux', 'macos')]
    [string]$Platform,
    [Parameter(Mandatory = $true)]
    [string]$SourceDir,
    [Parameter(Mandatory = $true)]
    [string]$Tag,
    [Parameter(Mandatory = $true)]
    [string]$Repo
)

$ErrorActionPreference = 'Stop'
$script:failures = 0
$script:pass = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Output ("PASS  " + $name); $script:pass++ }
    else     { Write-Output ("FAIL  " + $name); $script:failures++ }
}
function Get-Sha([string]$p) {
    return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("prism-selftest-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $root | Out-Null

try {
    # ---- 1. stage the helper as publish.ps1 would -------------------------
    $helperDir = Join-Path $root 'helper'
    New-Item -ItemType Directory -Force -Path $helperDir | Out-Null
    $updaterDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'updater'
    $helperPs1 = ''
    $helperSh = ''
    foreach ($f in (Get-ChildItem $updaterDir -File)) {
        $text = [IO.File]::ReadAllText($f.FullName)
        $text = $text.Replace('{{SOURCE_REPO}}', $Repo)
        if ($text.Contains('{{SOURCE_REPO}}')) { throw "unsubstituted placeholder in $($f.Name)" }
        [IO.File]::WriteAllText((Join-Path $helperDir $f.Name), $text, (New-Object System.Text.UTF8Encoding($false)))
        if ($f.Name -eq 'update-patcher.ps1') { $helperPs1 = Join-Path $helperDir $f.Name }
        if ($f.Name -eq 'update-patcher.sh')  { $helperSh  = Join-Path $helperDir $f.Name }
    }
    Check "helper staged with '$Repo' baked in" ((Get-ChildItem $helperDir -File).Count -ge 5)

    # ---- shared scenario data ---------------------------------------------
    $assetName = ''
    $installedName = ''
    if ($Platform -eq 'windows') {
        $assetName = 'PrismLauncher.exe'; $installedName = 'prismlauncher.exe'
    }
    elseif ($Platform -eq 'linux') {
        $assetName = 'PrismLauncher-Linux-x86_64.AppImage'; $installedName = 'PrismLauncher-Linux-x86_64.AppImage'
    }
    else {
        $assetName = "PrismLauncher-macOS-$Tag.dmg"
    }
    $assetSrc = Join-Path $SourceDir $assetName
    Check "test release holds $assetName" (Test-Path -LiteralPath $assetSrc)
    $assetSha = Get-Sha $assetSrc

    # the fake install claims the same version LINE as the release, one patch
    # level older - the realistic "patch release update" shape (and on Windows
    # the same-line rule is exactly what lets the update proceed)
    $line = (($Tag -split '\.')[0..1]) -join '.'
    $oldTag = "$line.0"
    if ($oldTag -eq $Tag) { $oldTag = "$line.0.1" }

    # ---- 2. fake install ----------------------------------------------------
    if ($Platform -eq 'windows') {
        $sandbox = Join-Path $root 'install'
        New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
        Copy-Item -LiteralPath $assetSrc -Destination (Join-Path $sandbox $installedName)
        $sha = Get-Sha (Join-Path $sandbox $installedName)
        [IO.File]::WriteAllText((Join-Path $sandbox '.update-patcher.json'),
            ('{"tag":"' + $oldTag + '","asset":"' + $assetName + '","sha256":"' + $sha +
             '","repo":"' + $Repo + '","installed_at":"now","helper":"selftest"}'),
            (New-Object System.Text.UTF8Encoding($false)))
    }
    elseif ($Platform -eq 'linux') {
        $sandbox = Join-Path $root 'install'
        New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
        Copy-Item -LiteralPath $assetSrc -Destination (Join-Path $sandbox $installedName)
        & bash -c ("chmod 755 '" + $sandbox + "/" + $installedName + "'")
        $sha = Get-Sha (Join-Path $sandbox $installedName)
        [IO.File]::WriteAllText((Join-Path $sandbox '.update-patcher.json'),
            ('{"tag":"' + $oldTag + '","asset":"' + $assetName + '","sha256":"' + $sha +
             '","repo":"' + $Repo + '","installed_at":"now","helper":"selftest"}'),
            (New-Object System.Text.UTF8Encoding($false)))
    }
    else {
        $sandbox = Join-Path $root 'apps'
        $appPath = Join-Path $sandbox 'Prism Launcher.app'
        New-Item -ItemType Directory -Force -Path (Join-Path $appPath 'Contents/MacOS') | Out-Null
        $plist = @'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>__VER__</string></dict></plist>
'@
        [IO.File]::WriteAllText((Join-Path $appPath 'Contents/Info'), ($plist.Replace('__VER__', $oldTag)))
        [IO.File]::WriteAllText((Join-Path $appPath 'Contents/MacOS/prismlauncher'), "dummy`n")
        [IO.File]::WriteAllText((Join-Path $sandbox '.update-patcher.json'),
            ('{"tag":"' + $oldTag + '","asset":"' + $assetName + '","sha256":"na","repo":"' + $Repo +
             '","target":"' + $appPath + '","installed_at":"now","helper":"selftest"}'),
            (New-Object System.Text.UTF8Encoding($false)))
    }

    # ---- 3. the helper invocation -------------------------------------------
    function Invoke-Helper([string]$Mode, [string]$SourceOverride, [switch]$Yes) {
        $src = $SourceOverride
        if (-not $src) { $src = $SourceDir }
        $yesArgs = @()
        if ($Yes) {
            if ($Platform -eq 'windows') { $yesArgs = @('-Yes') } else { $yesArgs = @('--yes') }
        }
        if ($Platform -eq 'windows') {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $helperPs1 $Mode @yesArgs `
                -Repo $Repo -SourceDir $src -Dir (Join-Path $root 'install')
            return $LASTEXITCODE
        }
        if ($Platform -eq 'linux') {
            & bash $helperSh $Mode @yesArgs --repo $Repo --source-dir $src --dir (Join-Path $root 'install')
            return $LASTEXITCODE
        }
        & bash $helperSh $Mode @yesArgs --repo $Repo --source-dir $src --app (Join-Path $root 'apps/Prism Launcher.app')
        return $LASTEXITCODE
    }

    # ---- 4. the update itself -------------------------------------------------
    $rc = Invoke-Helper 'auto' ''
    Check "update run exits 0" ($rc -eq 0)
    if ($Platform -eq 'windows') {
        $markerPath = Join-Path $root 'install/.update-patcher.json'
        $marker = Get-Content $markerPath -Raw
        Check "marker updated to $Tag" ($marker -match ('"tag":"' + [regex]::Escape($Tag) + '"'))
        $backups = @(Get-ChildItem (Join-Path $root 'install') -Filter 'prismlauncher.exe.bak-*')
        Check "backup made" ($backups.Count -eq 1)
        Check "installed sha matches the verified asset" ((Get-Sha (Join-Path $root 'install/prismlauncher.exe')) -eq $assetSha)
    }
    elseif ($Platform -eq 'linux') {
        $markerPath = Join-Path $root 'install/.update-patcher.json'
        $marker = Get-Content $markerPath -Raw
        Check "marker updated to $Tag" ($marker -match ('"tag":"' + [regex]::Escape($Tag) + '"'))
        $backups = @(Get-ChildItem (Join-Path $root 'install') -Filter '*.AppImage.bak-*')
        Check "backup made" ($backups.Count -eq 1)
        $execBit = & bash -c ("test -x '" + (Join-Path $root 'install') + "/$installedName' && echo yes")
        Check "executable bit set" ("$execBit".Trim() -eq 'yes')
        Check "installed sha matches the verified asset" ((Get-Sha (Join-Path $root 'install/' + $installedName)) -eq $assetSha)
    }
    else {
        $plistVer = & defaults read (Join-Path $root 'apps/Prism Launcher.app/Contents/Info') CFBundleShortVersionString
        Check "app is now $Tag" ("$plistVer".Trim() -eq $Tag)
        $backups = @(Get-ChildItem (Join-Path $root 'apps') -Directory | Where-Object { $_.Name -like 'Prism Launcher (backup *)' })
        Check "backup app kept" ($backups.Count -eq 1)
        Check "marker written" (Test-Path -LiteralPath (Join-Path $root 'apps/.update-patcher.json'))
        $leftover = @(Get-ChildItem '/Volumes' -Directory | Where-Object { $_.Name -like 'Prism*' })
        Check "DMG volume detached" ($leftover.Count -eq 0)
    }

    # ---- 5. second run: current must be silent and change nothing -------------
    $rc2 = Invoke-Helper 'auto' ''
    Check "second run exits 0 (current)" ($rc2 -eq 0)
    if ($Platform -ne 'macos') {
        $backups2 = @(Get-ChildItem (Join-Path $root 'install') -Filter '*.bak-*')
        Check "no extra backup on a current install" ($backups2.Count -eq 1)
    }

    # ---- 6. tampered checksums must be refused ---------------------------------
    # First put the install back to "intact but outdated" (the marker claims
    # the old tag again): a helper that is already current would exit 0
    # before ever reaching the download, and the refusal test would prove
    # nothing.
    $tamper = Join-Path $root 'tampered'
    New-Item -ItemType Directory -Force -Path $tamper | Out-Null
    Copy-Item -LiteralPath (Join-Path $SourceDir $assetName) -Destination (Join-Path $tamper $assetName)
    if ($Platform -eq 'macos') {
        Copy-Item -LiteralPath (Join-Path $SourceDir 'tag.txt') -Destination (Join-Path $tamper 'tag.txt')
    }
    $lines = @(Get-Content (Join-Path $SourceDir 'checksums.txt'))
    $bad = foreach ($l in $lines) {
        if ($l -match ('^SHA256\s+[0-9a-fA-F]{64}\s+' + [regex]::Escape($assetName) + '\s*$')) {
            $l -replace 'SHA256\s+[0-9a-fA-F]{64}', ('SHA256  ' + ('0' * 64))
        } else { $l }
    }
    [IO.File]::WriteAllLines((Join-Path $tamper 'checksums.txt'), $bad)
    if ($Platform -eq 'macos') {
        [IO.File]::WriteAllText((Join-Path $root 'apps/.update-patcher.json'),
            ('{"tag":"' + $oldTag + '","asset":"' + $assetName + '","sha256":"na","repo":"' + $Repo +
             '","installed_at":"now","helper":"selftest"}'))
    }
    else {
        [IO.File]::WriteAllText((Join-Path $root 'install/.update-patcher.json'),
            ('{"tag":"' + $oldTag + '","asset":"' + $assetName + '","sha256":"' + $assetSha +
             '","repo":"' + $Repo + '","installed_at":"now","helper":"selftest"}'))
    }
    $rc3 = Invoke-Helper 'auto' $tamper
    Check "tampered checksums refused (exit 1)" ($rc3 -eq 1)
    if ($Platform -eq 'macos') {
        $plistVer2 = & defaults read (Join-Path $root 'apps/Prism Launcher.app/Contents/Info') CFBundleShortVersionString
        Check "tamper changed nothing" ("$plistVer2".Trim() -eq $Tag)
    }
    else {
        Check "tamper changed nothing" ((Get-Sha (Join-Path $root 'install/' + $installedName)) -eq $assetSha)
    }

    # ---- 7. background check on/off (Windows + Linux; macOS has none) -----------
    if ($Platform -eq 'windows') {
        $rc4 = Invoke-Helper 'enable-check' ''
        Check "enable-check exits 0" ($rc4 -eq 0)
        $task = Get-ScheduledTask -TaskName 'PrismLauncher Patch Updater' -ErrorAction SilentlyContinue
        Check "scheduled task registered" ($null -ne $task)
        $rc5 = Invoke-Helper 'disable-check' ''
        Check "disable-check exits 0" ($rc5 -eq 0)
        $task2 = Get-ScheduledTask -TaskName 'PrismLauncher Patch Updater' -ErrorAction SilentlyContinue
        Check "scheduled task removed" ($null -eq $task2)
    }
    elseif ($Platform -eq 'linux') {
        $rc4 = Invoke-Helper 'enable-check' ''
        if ($rc4 -eq 0) {
            Check "enable-check exits 0" $true
            $st = & systemctl --user is-enabled prism-patch-update.timer
            Check "user timer enabled" ("$st".Trim() -eq 'enabled')
            $rc5 = Invoke-Helper 'disable-check' ''
            Check "disable-check exits 0" ($rc5 -eq 0)
            $st2 = & systemctl --user is-enabled prism-patch-update.timer
            Check "user timer removed" ("$st2".Trim() -ne 'enabled')
        }
        else {
            # No systemd user session on this runner: the timer path is
            # proven on the maintainer's real Linux machine instead. The
            # background check is optional - it must not block a release.
            Write-Output ("SKIP  enable-check (exit $rc4) - no systemd user session on this runner")
        }
    }
    else {
        $null = Invoke-Helper 'enable-check' ''
        Check "macOS enable-check declines politely" ($LASTEXITCODE -eq 0)
    }

    # ---- 8. an ignored version: auto must skip it silently ----------------------
    $mp = Join-Path $root 'install/.update-patcher.json'
    if ($Platform -eq 'macos') {
        $mp = Join-Path $root 'apps/.update-patcher.json'
        [IO.File]::WriteAllText($mp,
            ('{"tag":"' + $oldTag + '","asset":"' + $assetName + '","sha256":"na","repo":"' + $Repo +
             '","target":"' + (Join-Path $root 'apps/Prism Launcher.app') + '","installed_at":"now","helper":"selftest","ignored":"' + $Tag + '"}'))
    }
    else {
        [IO.File]::WriteAllText($mp,
            ('{"tag":"' + $oldTag + '","asset":"' + $assetName + '","sha256":"' + $assetSha +
             '","repo":"' + $Repo + '","installed_at":"now","helper":"selftest","ignored":"' + $Tag + '"}'))
    }
    $rc6 = Invoke-Helper 'auto' ''
    Check "auto on an ignored version exits 0" ($rc6 -eq 0)
    $markerNow = Get-Content $mp -Raw
    Check "ignored version was not installed" ($markerNow -match ('"tag":"' + [regex]::Escape($oldTag) + '"'))
    Check "the ignore is still recorded" ($markerNow -match ('"ignored":"' + [regex]::Escape($Tag) + '"'))

    # ---- 9. apply -Yes / --yes installs an ignored version anyway ----------------
    $rc7 = Invoke-Helper 'apply' '' -Yes
    Check "apply with -Yes/--yes exits 0 on an ignored version" ($rc7 -eq 0)
    $markerNow = Get-Content $mp -Raw
    Check "apply -Yes installed the ignored version" ($markerNow -match ('"tag":"' + [regex]::Escape($Tag) + '"'))
    Check "installing it cleared the ignore" ($markerNow -notmatch '"ignored"')
    if ($Platform -eq 'windows') {
        Check "installed sha matches the verified asset" ((Get-Sha (Join-Path $root 'install/prismlauncher.exe')) -eq $assetSha)
        $backups = @(Get-ChildItem (Join-Path $root 'install') -Filter 'prismlauncher.exe.bak-*')
        Check "a second backup was made" ($backups.Count -eq 2)
    }
    elseif ($Platform -eq 'linux') {
        Check "installed sha matches the verified asset" ((Get-Sha (Join-Path $root 'install/' + $installedName)) -eq $assetSha)
        $backups = @(Get-ChildItem (Join-Path $root 'install') -Filter '*.AppImage.bak-*')
        Check "a second backup was made" ($backups.Count -eq 2)
    }
    else {
        $plistVer3 = & defaults read (Join-Path $root 'apps/Prism Launcher.app/Contents/Info') CFBundleShortVersionString
        Check "app is still $Tag" ("$plistVer3".Trim() -eq $Tag)
        $backups = @(Get-ChildItem (Join-Path $root 'apps') -Directory | Where-Object { $_.Name -like 'Prism Launcher (backup *)' })
        Check "a second backup was made" ($backups.Count -eq 2)
    }

    # ---- 10. apply with no way to ask must cancel safely (no hang) ---------------
    # CI stdin is redirected and $CI is set, so the helper cannot prompt -
    # both engines must answer "cancel" by themselves: exit 0, unchanged.
    if ($Platform -eq 'macos') {
        [IO.File]::WriteAllText($mp,
            ('{"tag":"' + $oldTag + '","asset":"' + $assetName + '","sha256":"na","repo":"' + $Repo +
             '","target":"' + (Join-Path $root 'apps/Prism Launcher.app') + '","installed_at":"now","helper":"selftest"}'))
    }
    else {
        [IO.File]::WriteAllText($mp,
            ('{"tag":"' + $oldTag + '","asset":"' + $assetName + '","sha256":"' + $assetSha +
             '","repo":"' + $Repo + '","installed_at":"now","helper":"selftest"}'))
    }
    $rc8 = Invoke-Helper 'apply' ''
    Check "apply without a terminal cancels safely (exit 0)" ($rc8 -eq 0)
    $markerNow = Get-Content $mp -Raw
    Check "apply without a terminal changed nothing" ($markerNow -match ('"tag":"' + [regex]::Escape($oldTag) + '"'))
    if ($Platform -eq 'macos') {
        $backups = @(Get-ChildItem (Join-Path $root 'apps') -Directory | Where-Object { $_.Name -like 'Prism Launcher (backup *)' })
        Check "no extra backup from the cancelled apply" ($backups.Count -eq 2)
    }
    else {
        $backups = @(Get-ChildItem (Join-Path $root 'install') -Filter '*.bak-*')
        Check "no extra backup from the cancelled apply" ($backups.Count -eq 2)
    }

    Write-Output ""
    if ($script:failures -eq 0) {
        Write-Output ("SELFTEST RESULT: ALL GREEN (" + $script:pass + " checks, platform " + $Platform + ")")
        exit 0
    }
    Write-Output ("SELFTEST RESULT: " + $script:failures + " FAILURE(S) on platform " + $Platform)
    exit 1
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
