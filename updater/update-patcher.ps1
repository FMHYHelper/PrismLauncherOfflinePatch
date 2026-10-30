# update-patcher.ps1 - the update helper for the offline-patched Prism
# Launcher build on Windows.
#
# This script is NOT part of the launcher. The patched launcher contains
# exactly the four published patches and nothing else - no updater, no
# phone-home - and that is a promise, not an accident: this helper lives
# outside the exe and does, by hand, what a user could do by hand:
# download the newest patched build from a repository's Releases, check
# it against checksums.txt, back the old file up, and swap it in.
#
# Modes:
#   apply          interactive update (the default; run by update-prism.cmd);
#                  asks Update / Cancel / Ignore this update; -Yes skips the
#                  questions and installs even an ignored version
#   auto           non-interactive: update when needed, silent when current
#                  (the mode the optional background task runs)
#   check          report only: installed version vs. latest release
#   enable-check   set up the optional daily background check (Task Scheduler)
#   disable-check  remove the background task again
#   status         show what is installed and what the background task is
#
# The source repository is baked in per release (the repo the asset came
# from). Override once with -Repo owner/name. All it ever talks to is the
# GitHub API and download servers of that one repository.
#
# Files:
#   .update-patcher.json  - marker written next to the installed exe; its
#                           ignored field records a version the user chose
#                           to skip (a newer release asks again)
#   *.bak-<timestamp>     - backups; they accumulate, delete old ones by hand
#
# Runs on Windows PowerShell 5.1 and pwsh.

param(
    [Parameter(Position = 0)]
    [string]$Mode = 'apply',
    [string]$Repo = '{{SOURCE_REPO}}',
    [string]$Dir = '',
    [string]$SourceDir = '',
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

$MarkerName    = '.update-patcher.json'
$InstalledName = 'prismlauncher.exe'
$AssetName     = 'PrismLauncher.exe'
$TaskName      = 'PrismLauncher Patch Updater'
$StableDir     = Join-Path $env:LOCALAPPDATA 'PrismPatcher'
$BkLog         = Join-Path $StableDir 'update-check.log'

# ---------------------------------------------------------------- helpers ----

function Info([string]$m) { Write-Host $m }
function Warn([string]$m) { Write-Host ("  note: " + $m) }
function Die([string]$m)  { throw $m }

function Get-FileSha([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Compare-PrismTags([string]$A, [string]$B) {
    # Numeric per-component tag compare ("11.1.1" vs "11.2.0"). Returns -1, 0, 1.
    # Missing or non-numeric components read as 0; an unknown version sorts oldest.
    $a = @(($A -replace '^v', '') -split '\.' | ForEach-Object { if ($_ -match '\d') { [int]($_ -replace '\D.*$', '') } else { 0 } })
    $b = @(($B -replace '^v', '') -split '\.' | ForEach-Object { if ($_ -match '\d') { [int]($_ -replace '\D.*$', '') } else { 0 } })
    $n = [Math]::Max($a.Count, $b.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = if ($i -lt $a.Count) { $a[$i] } else { 0 }
        $y = if ($i -lt $b.Count) { $b[$i] } else { 0 }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    return 0
}

function Read-Checksums([string]$Path) {
    # checksums.txt lines: "SHA256  <hash>  <name>"
    $map = @{}
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^SHA256\s+([0-9a-fA-F]{64})\s+(.+)$') {
            $map[$Matches[2].Trim()] = $Matches[1].ToLowerInvariant()
        }
    }
    if ($map.Count -eq 0) { Die "checksums.txt at $Path has no readable entries" }
    return $map
}

function Get-ReleaseInfo {
    # Returns @{ tag; body; assets (name -> source path or download URL) }.
    # With -SourceDir the "release" is a local directory holding the assets,
    # a checksums.txt and a tag.txt - used by the kit's self-test and rigs.
    if ($SourceDir) {
        if (-not (Test-Path -LiteralPath $SourceDir)) { Die "SourceDir not found: $SourceDir" }
        $tagFile = Join-Path $SourceDir 'tag.txt'
        if (-not (Test-Path -LiteralPath $tagFile)) { Die "tag.txt missing in $SourceDir" }
        $tag = ([string](Get-Content -LiteralPath $tagFile -Raw)).Trim()
        $assets = @{}
        Get-ChildItem -LiteralPath $SourceDir -File | ForEach-Object {
            if ($_.Name -ne 'tag.txt') { $assets[$_.Name] = $_.FullName }
        }
        return @{ tag = $tag; body = ''; assets = $assets }
    }
    if ($Repo -match '\{\{' -or [string]::IsNullOrWhiteSpace($Repo)) {
        Die (@(
            'This copy of the helper is not configured with a source repository.',
            'Download update-patcher.ps1 from the Releases page of a',
            'PrismLauncherOfflinePatch repository - the release-page copy carries',
            'its source already - or pass it once with -Repo owner/name.'
        ) -join "`n")
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $rel = Invoke-RestMethod -Uri ("https://api.github.com/repos/" + $Repo + "/releases/latest") -Headers @{ 'User-Agent' = 'prism-patch-update-helper' }
    $assets = @{}
    foreach ($a in @($rel.assets)) { $assets[$a.name] = $a.browser_download_url }
    $body = [string]$rel.body
    return @{ tag = [string]$rel.tag_name; body = $body; assets = $assets }
}

function Invoke-AssetDownload([string]$Source, [string]$OutFile) {
    # $Source is a URL (real releases) or a local path (test mode).
    if ($Source -notmatch '^https?://') {
        Copy-Item -LiteralPath $Source -Destination $OutFile -Force
        return
    }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # curl chatters on stderr; 5.1 trap
    try {
        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
        if ($curl) {
            & curl.exe -fsSL --retry 3 -o $OutFile $Source
            if ($LASTEXITCODE -ne 0) { Die "download failed (curl exit $LASTEXITCODE): $Source" }
        }
        else {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Source -OutFile $OutFile -UserAgent 'prism-patch-update-helper'
            if (-not (Test-Path -LiteralPath $OutFile)) { Die "download produced no file: $Source" }
        }
    }
    finally { $ErrorActionPreference = $prevEap }
}

function Show-Toast([string]$Title, [string]$Body) {
    # Best-effort Windows toast; never fatal, log-only when unavailable.
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $t1 = $xml.GetElementsByTagName('text').Item(0); $t1.AppendChild($xml.CreateTextNode($Title)) | Out-Null
        $t2 = $xml.GetElementsByTagName('text').Item(1); $t2.AppendChild($xml.CreateTextNode($Body)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Prism Launcher (patched)').Show($toast)
    }
    catch {
        Info ("  (no toast: " + $_.Exception.Message + ")")
    }
}

function Test-LauncherRunning {
    return [bool](Get-Process -Name 'prismlauncher' -ErrorAction SilentlyContinue)
}

function Get-UpdateChoice([string]$Title, [string]$Message) {
    # The interactive question with three answers:
    #   update - fetch, verify and swap now
    #   cancel - do nothing until the next check
    #   ignore - record this exact version so it stops being suggested
    #            (a newer version asks again)
    # A windowed dialog first, the terminal as fallback, and "cancel" - the
    # answer that changes nothing - whenever no question can be asked at
    # all (redirected input, a service session, the self-test's CI
    # runners). Never hangs.
    try {
        if ($env:CI -or [Console]::IsInputRedirected -or -not [Environment]::UserInteractive) { return 'cancel' }
    }
    catch { return 'cancel' }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $form = New-Object System.Windows.Forms.Form
        $form.Text = $Title
        $form.ClientSize = New-Object System.Drawing.Size(430, 108)
        $form.StartPosition = 'CenterScreen'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.TopMost = $true
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Message
        $label.Location = New-Object System.Drawing.Point(12, 12)
        $label.Size = New-Object System.Drawing.Size(406, 42)
        $form.Controls.Add($label)
        $bUpdate = New-Object System.Windows.Forms.Button
        $bUpdate.Text = 'Update'
        $bUpdate.Location = New-Object System.Drawing.Point(12, 66)
        $bUpdate.Size = New-Object System.Drawing.Size(132, 30)
        $bUpdate.DialogResult = [System.Windows.Forms.DialogResult]::Yes
        $form.Controls.Add($bUpdate)
        $bCancel = New-Object System.Windows.Forms.Button
        $bCancel.Text = 'Cancel'
        $bCancel.Location = New-Object System.Drawing.Point(150, 66)
        $bCancel.Size = New-Object System.Drawing.Size(132, 30)
        $bCancel.DialogResult = [System.Windows.Forms.DialogResult]::No
        $form.Controls.Add($bCancel)
        $bIgnore = New-Object System.Windows.Forms.Button
        $bIgnore.Text = 'Ignore this update'
        $bIgnore.Location = New-Object System.Drawing.Point(288, 66)
        $bIgnore.Size = New-Object System.Drawing.Size(130, 30)
        $bIgnore.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Controls.Add($bIgnore)
        $form.AcceptButton = $bUpdate
        $form.CancelButton = $bCancel
        $r = $form.ShowDialog()
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { return 'update' }
        if ($r -eq [System.Windows.Forms.DialogResult]::Cancel) { return 'ignore' }
        return 'cancel'
    }
    catch {
        try {
            $answer = Read-Host ("  " + $Message + " [Enter = update, i = ignore this update, anything else = cancel]")
            if ($answer -match '^(i|ign)') { return 'ignore' }
            if ($answer -match '^(n|no|c|ca)') { return 'cancel' }
            return 'update'
        }
        catch { return 'cancel' }
    }
}

function Read-Marker([string]$DirPath) {
    $p = Join-Path $DirPath $MarkerName
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return Get-Content -LiteralPath $p -Raw | ConvertFrom-Json }
    catch { return $null }
}

function Write-Marker([string]$DirPath, [hashtable]$M) {
    $p = Join-Path $DirPath $MarkerName
    $json = $M | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($p, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Add-IgnoreMarker([string]$DirPath, [string]$IgnoredTag) {
    # Records "the user chose to skip this exact version" on the marker,
    # keeping every field it already carries.
    $rec = @{ helper = 'kit-22' }
    $m = Read-Marker $DirPath
    if ($m) {
        foreach ($p in $m.PSObject.Properties) { $rec[$p.Name] = $p.Value }
    }
    $rec['ignored'] = $IgnoredTag
    $rec['ignored_at'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Marker $DirPath $rec
}

function Resolve-InstallDir {
    # The folder holding prismlauncher.exe. -Dir wins; then the helper's
    # recorded setting; then the official installer's default location.
    if ($Dir) {
        if (-not (Test-Path -LiteralPath (Join-Path $Dir $InstalledName))) {
            Die "no $InstalledName in $Dir"
        }
        return (Resolve-Path -LiteralPath $Dir).Path
    }
    $settings = $null
    $sp = Join-Path $StableDir 'settings.json'
    if (Test-Path -LiteralPath $sp) {
        try { $settings = Get-Content -LiteralPath $sp -Raw | ConvertFrom-Json } catch { $settings = $null }
    }
    if ($settings -and $settings.dir) {
        if (Test-Path -LiteralPath (Join-Path $settings.dir $InstalledName)) { return $settings.dir }
        Warn "the recorded folder $($settings.dir) no longer holds the launcher"
    }
    $def = Join-Path $env:LOCALAPPDATA 'Programs\PrismLauncher'
    if (Test-Path -LiteralPath (Join-Path $def $InstalledName)) { return $def }
    if ($Mode -eq 'auto' -or $Mode -eq 'check') {
        Die ("could not find the Prism Launcher folder. Run 'update-prism.cmd' once, " +
             "or pass the folder with -Dir.")
    }
    Info "The launcher's folder was not found in the usual place."
    $user = Read-Host "Paste the full path of your Prism Launcher folder (the one with prismlauncher.exe)"
    if (-not (Test-Path -LiteralPath (Join-Path $user $InstalledName))) {
        Die "no $InstalledName in $user"
    }
    return (Resolve-Path -LiteralPath $user).Path
}

function Get-InstalledState([string]$DirPath) {
    # Returns installed tag (or '') plus whether the exe matches the marker.
    $exePath = Join-Path $DirPath $InstalledName
    $marker = Read-Marker $DirPath
    $currentSha = Get-FileSha $exePath
    if ($marker) {
        $intact = ($marker.sha256 -eq $currentSha)
        return @{ tag = [string]$marker.tag; intact = $intact; via = 'marker'; ignored = [string]$marker.ignored }
    }
    return @{ tag = (Get-NativeVersion $DirPath); intact = $false; via = 'file properties'; ignored = '' }
}

function Get-DisplayRef($st, [string]$DirPath) {
    # What to show the user as the installed version: the marker's tag when
    # the exe still matches it, the exe's own version otherwise (after an
    # official update replaced the file, the marker's tag is stale).
    if ($st.intact -and $st.tag) { return [string]$st.tag }
    $native = Get-NativeVersion $DirPath
    if ($native) { return $native }
    return [string]$st.tag
}

function Get-NativeVersion([string]$DirPath) {
    # The exe's own version string (works even after an official update
    # replaced the file and the marker no longer matches).
    $exePath = Join-Path $DirPath $InstalledName
    $vi = (Get-Item -LiteralPath $exePath).VersionInfo
    $ver = [string]$vi.ProductVersion
    if (-not $ver) { $ver = [string]$vi.FileVersion }
    return $ver
}

function Resolve-Action([hashtable]$Release, $st, [string]$DirPath) {
    # The one decision every mode goes through. Returns:
    #   current             - intact install at or above the latest release
    #   wait-newer-official - a newer OFFICIAL version is installed; its patched
    #                         build is not out yet. Touching it would downgrade.
    #   wait-jump           - Windows-only: the new release is a different major-
    #                         minor line than the folder. The Qt runtime files
    #                         must move with the exe, and only the official
    #                         update rights them - so the official update goes
    #                         first, then this helper re-applies the patch.
    #   update              - safe to fetch and swap
    $newest = $Release.tag
    if ($st.intact -and $st.tag -and ((Compare-PrismTags $st.tag $newest) -ge 0)) { return 'current' }
    $installedRef = $st.tag
    if (-not $st.intact) {
        $native = Get-NativeVersion $DirPath
        if ($native) { $installedRef = $native }
        if ($native -and (Compare-PrismTags $native $newest) -gt 0) {
            return 'wait-newer-official'
        }
    }
    if ($installedRef -and ((Compare-PrismTags $installedRef $newest) -lt 0)) {
        $installedLine = (($installedRef -split '\.')[0..1]) -join '.'
        $newestLine = (($newest -split '\.')[0..1]) -join '.'
        if ($installedLine -ne $newestLine) { return 'wait-jump' }
    }
    return 'update'
}

function Backup-Path([string]$DirPath) {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    return (Join-Path $DirPath ($InstalledName + '.bak-' + $stamp))
}

function Invoke-Update([hashtable]$Release, [string]$DirPath, [bool]$NonInteractive) {
    $exePath = Join-Path $DirPath $InstalledName
    if (-not $Release.assets.ContainsKey($AssetName)) {
        Die ("this release (" + $Release.tag + ") has no " + $AssetName + " - the copy may not build Windows")
    }
    if (-not $Release.assets.ContainsKey('checksums.txt')) {
        Die ("this release (" + $Release.tag + ") has no checksums.txt - nothing can be verified, nothing was changed")
    }

    $tmp = Join-Path $DirPath (".update-patcher.tmp-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        Info "  fetching checksums.txt ..."
        Invoke-AssetDownload $Release.assets['checksums.txt'] (Join-Path $tmp 'checksums.txt')
        $sums = Read-Checksums (Join-Path $tmp 'checksums.txt')
        if (-not $sums.ContainsKey($AssetName)) { Die "checksums.txt has no entry for $AssetName" }
        $expected = $sums[$AssetName]

        Info ("  downloading " + $AssetName + " ...")
        Invoke-AssetDownload $Release.assets[$AssetName] (Join-Path $tmp $AssetName)
        $got = Get-FileSha (Join-Path $tmp $AssetName)
        if ($got -ne $expected) {
            Die ("checksum mismatch for " + $AssetName + " - expected " + $expected + ", got " + $got +
                 ". The download is not the published file; nothing was changed.")
        }
        Info "  checksum verified."

        if ($NonInteractive) {
            if (Test-LauncherRunning) {
                Show-Toast 'Prism Launcher (patched)' ("Update to " + $Release.tag + " is ready - close Prism, then run update-prism.cmd")
                Add-Log ("update " + $Release.tag + " deferred: the launcher was running")
                return 'deferred'
            }
        }
        else {
            if (Test-LauncherRunning) {
                Info "  Prism Launcher is running. Close it, then press Enter (Ctrl+C to abort)."
                try { [void](Read-Host "  ready when the launcher is closed") }
                catch { Info "  cancelled; nothing changed."; return 'cancelled' }
            }
            $choice = Get-UpdateChoice 'Prism Launcher (patched)' ("Install " + $Release.tag + " now? The current file is backed up first.")
            if ($choice -eq 'ignore') {
                Add-IgnoreMarker $DirPath $Release.tag
                Info ("  " + $Release.tag + " is noted as ignored - it will not be suggested again")
                Info "  (a newer version still asks; 'apply -Yes' installs it anyway)."
                Add-Log ("update " + $Release.tag + " ignored (user choice)")
                return 'ignored'
            }
            if ($choice -ne 'update') { Info "  cancelled; nothing changed."; return 'cancelled' }
        }

        $backup = Backup-Path $DirPath
        Move-Item -LiteralPath $exePath -Destination $backup
        Copy-Item -LiteralPath (Join-Path $tmp $AssetName) -Destination $exePath
        $placed = Get-FileSha $exePath
        if ($placed -ne $expected) { Die "the swapped file does not match the verified checksum - inspect $DirPath" }

        $wm = @{
            tag          = $Release.tag
            asset        = $AssetName
            sha256       = $placed
            repo         = $Repo
            installed_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            helper       = 'kit-22'
        }
        # an ignore of an OLDER version carries forward; installing the
        # ignored version itself is what clears it
        $oldMarker = Read-Marker $DirPath
        if ($oldMarker -and $oldMarker.ignored -and ([string]$oldMarker.ignored -ne $Release.tag)) {
            $wm['ignored'] = [string]$oldMarker.ignored
        }
        Write-Marker $DirPath $wm
        Info ("  old exe kept as " + (Split-Path $backup -Leaf))
        Info ("  done - the patched launcher is now " + $Release.tag + ". Start it and check the account picker works.")
        Add-Log ("updated to " + $Release.tag)
        return 'updated'
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    }
}

function Add-Log([string]$Line) {
    try {
        if (-not (Test-Path -LiteralPath $StableDir)) { New-Item -ItemType Directory -Force -Path $StableDir | Out-Null }
        Add-Content -LiteralPath $BkLog -Value ("[" + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + "] " + $Line)
    } catch { }
}

# ------------------------------------------------------------ background ----

function Enable-Check {
    if (-not (Test-Path -LiteralPath $StableDir)) { New-Item -ItemType Directory -Force -Path $StableDir | Out-Null }
    $stableScript = Join-Path $StableDir 'update-patcher.ps1'
    Copy-Item -LiteralPath $PSCommandPath -Destination $stableScript -Force
    # record the folder this machine's launcher lives in, once, so the daily
    # run needs no prompts
    $instDir = Resolve-InstallDir
    $s = @{ dir = $instDir; saved_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Join-Path $StableDir 'settings.json'), $s + "`n", (New-Object System.Text.UTF8Encoding($false)))

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $stableScript + '" auto')
    $trigger = New-ScheduledTaskTrigger -Daily -At 12:00
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Add-Log "background check enabled (daily 12:00, catch-up when the machine was off)"
    Info ("Background check is on: a hidden daily task '" + $TaskName + "' runs at 12:00 and")
    Info "catches up after a missed slot. It updates silently when the launcher is closed,"
    Info "stays silent about a version you chose to ignore, and only notifies when a"
    Info "swap must wait for you. Everything it does lands in"
    Info ("  " + $BkLog)
    Info "Remove it anytime with update-check-disable.cmd."
}

function Disable-Check {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Add-Log "background check disabled"
        Info "Background check removed. The copy of the helper stays in:"
        Info ("  " + $StableDir)
    }
    else {
        Info "Background check is already off; nothing to do."
    }
}

function Get-TaskState {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) { return $t.State }
    return 'not installed'
}

# ------------------------------------------------------------------ main ----

$release = $null
if ($Mode -in @('apply', 'auto', 'check', 'status')) {
    $release = Get-ReleaseInfo
}

switch ($Mode) {
    'check' {
        $dir = Resolve-InstallDir
        $st = Get-InstalledState $dir
        Info ("Latest patched release:  " + $release.tag + "   (source: " + $Repo + ")")
        Info ("Installed here:          " + $(if ($st.tag) { $st.tag + " (" + $st.via + ")" } else { 'unknown' }))
        if (-not $st.intact -and $st.via -eq 'marker') { Warn "the exe no longer matches what the helper installed (official update ran?)" }
        if ((Compare-PrismTags $st.tag $release.tag) -lt 0) {
            if ($st.ignored -eq $release.tag) {
                Info ("The available update (" + $release.tag + ") is the one you chose to ignore;")
                Info "'update-patcher.ps1 apply -Yes' installs it anyway."
            } else {
                Info "An update is available - run update-prism.cmd to apply it."
            }
        } else {
            Info "This install is up to date."
        }
    }
    'status' {
        $dir = Resolve-InstallDir
        $st = Get-InstalledState $dir
        Info ("Source repository:  " + $Repo)
        Info ("Latest release:     " + $release.tag)
        Info ("Installed:          " + $(if ($st.tag) { $st.tag + " (" + $st.via + ", intact: " + $st.intact + ")" } else { 'unknown' }))
        if ($st.ignored) { Info ("Ignored version:    " + $st.ignored) }
        Info ("Background task:    " + (Get-TaskState))
        if (Test-Path -LiteralPath $BkLog) { Info ("Log:                " + $BkLog) }
    }
    'apply' {
        $dir = Resolve-InstallDir
        $st = Get-InstalledState $dir
        Info ("Prism Launcher folder: " + $dir)
        Info ("Installed: " + $(if ($st.tag) { $st.tag } else { 'unknown version' }) + " | latest patched release: " + $release.tag)
        $action = Resolve-Action $release $st $dir
        if ($action -eq 'current') {
            Info "Already up to date - nothing to do."
        }
        elseif ($action -eq 'wait-newer-official') {
            Warn ("the installed launcher (" + (Get-NativeVersion $dir) + ") is newer than the newest patched")
            Warn ("build (" + $release.tag + "): an official update ran and its patched build is not out yet.")
            Info "Nothing was changed. Run this helper again once your copy has built the new version."
        }
        elseif ($action -eq 'wait-jump') {
            Warn ("a jump from " + (Get-DisplayRef $st $dir) + " to " + $release.tag + " needs the official update first: on Windows")
            Info "the folder's Qt runtime files must move with the exe, and the official update is"
            Info "what rights them. Run the launcher's *Check for Updates* (or the official"
            Info "installer), then run this helper again - it re-applies the patch on the"
            Info "updated folder on its own."
        }
        else {
            if ($st.ignored -eq $release.tag -and -not $Yes) {
                Info ("You chose to ignore " + $release.tag + ", so the helper does not suggest it again.")
                Info "The next patched release will ask normally. To install this one anyway:"
                Info "  update-patcher.ps1 apply -Yes"
                Info "Nothing was changed."
            }
            else {
                if (-not $st.intact -and $st.via -eq 'marker') {
                    Warn "the exe is not the one the helper installed - an official update or a manual"
                    Warn "replace ran in between. Applying the newest patched build on top is the fix;"
                    Info "the current file gets a backup first."
                }
                Info ""
                Info ("What changed in " + $release.tag + ":")
                if ($release.body) {
                    $release.body -split "`n" | Select-Object -First 40 | ForEach-Object { Info ("  " + $_) }
                } else {
                    Info ("  see the release page: https://github.com/" + $Repo + "/releases")
                }
                Info ""
                $null = Invoke-Update $release $dir $Yes
            }
        }
    }
    'auto' {
        # Non-interactive: used by the daily task (and the self-test).
        # Silent when current; updates when it can; defers with a
        # notification when a swap must wait for the user. Requires the
        # helper to know the folder: run update-prism.cmd once first.
        $dir = Resolve-InstallDir
        $st = Get-InstalledState $dir
        $action = Resolve-Action $release $st $dir
        if ($action -eq 'current') {
            # the scheduled run ends here without a peep
        }
        elseif ($action -eq 'wait-newer-official') {
            Add-Log ("official " + (Get-NativeVersion $dir) + " is newer than the newest patched build; waiting")
        }
        elseif ($action -eq 'wait-jump') {
            Add-Log ("version jump to " + $release.tag + " needs the official update first; waiting")
            Show-Toast 'Prism Launcher (patched)' ("Prism " + $release.tag + " needs the official update first - then run update-prism.cmd")
        }
        elseif ($st.ignored -eq $release.tag) {
            # the user said no to exactly this version; the scheduled run
            # stays silent until a NEWER release asks
            Add-Log ("update " + $release.tag + " skipped: it is the version you chose to ignore (apply -Yes installs it anyway)")
        }
        else {
            if (-not $st.intact -and $st.via -eq 'marker') {
                Add-Log ("the exe no longer matches the marker (installed " + $st.tag + "); re-applying " + $release.tag)
            }
            $r = Invoke-Update $release $dir $true
            if ($r -eq 'updated') {
                Show-Toast 'Prism Launcher (patched)' ("Updated to " + $release.tag)
            }
            elseif ($r -eq 'deferred') {
                Info "deferred - will try again on the next scheduled run."
            }
        }
    }
    'enable-check'  { Enable-Check }
    'disable-check' { Disable-Check }
    default {
        Die "unknown mode '$Mode'. Use: apply | auto | check | enable-check | disable-check | status"
    }
}
