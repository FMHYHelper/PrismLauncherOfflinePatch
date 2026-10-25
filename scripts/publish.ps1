# Publishes the releases of one workflow run. Called by the workflow's
# publish job on a Linux runner, with the kit checked out at the repository
# root and every build job's output downloaded as a directory named
# release-<tag>-<platform>.
#
# For every tag found among those directories it:
#   1. concatenates the kit's patch files into source-patches-<tag>.patch
#      (the exact text of the publicly readable files under patches/),
#   2. hashes every file of the release (built binaries plus the patch
#      bundle) into a single checksums.txt,
#   3. renders docs/release-notes-template.md with the tag, and
#   4. creates the release - or, for a force_rebuild of one that already
#      exists, deletes and recreates it first; without force it refreshes
#      the existing release's assets instead.
#
# Every step verifies itself; anything unexpected fails the job, and the
# state bookkeeping then treats the run as failed (nothing is marked
# handled when a release did not end up visible).

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$repoRoot = Find-RepoRoot

if (-not $env:GH_TOKEN) { throw "GH_TOKEN is not set" }
if (-not $env:GH_REPO)  { throw "GH_REPO is not set" }

# ---- tags this run meant to publish, with their release flags -------------
$meta = @{}
$buildJson = $env:BUILD_JSON
if ([string]::IsNullOrWhiteSpace($buildJson)) { throw "BUILD_JSON is not set" }
$parsed = $buildJson | ConvertFrom-Json
if ($parsed -and $parsed.include) {
    foreach ($e in @($parsed.include)) {
        if (-not $e) { continue }
        $meta[[string]$e.tag] = [pscustomobject]@{
            prerelease = [bool]$e.prerelease
            force      = [bool]$e.force
        }
    }
}
if ($meta.Count -eq 0) { throw "No builds found in BUILD_JSON" }

# ---- group the downloaded artifacts by tag ---------------------------------
$artPattern = '^release-(?<tag>.+)-(?<platform>windows|linux|macos)$'
$byTag = @{}
$dirs = @(Get-ChildItem -Path $PWD -Directory | Where-Object { $_.Name -match $artPattern })
if ($dirs.Count -eq 0) { throw "No release-<tag>-<platform> artifact directories were downloaded" }

foreach ($d in $dirs) {
    $m = [regex]::Match($d.Name, $artPattern)
    $tag = $m.Groups['tag'].Value
    if (-not $byTag[$tag]) {
        $byTag[$tag] = @{ files = @(); platforms = @() }
    }
    $files = @(Get-ChildItem -Path $d.FullName -File -Recurse | Where-Object { -not $_.PSIsContainer })
    if ($files.Count -eq 0) { throw "Artifact $($d.Name) contains no files" }
    $byTag[$tag].platforms += $m.Groups['platform'].Value
    $byTag[$tag].files += $files
}

# ---- publish one release per tag -------------------------------------------
$utf8 = New-Object System.Text.UTF8Encoding($false)
foreach ($tag in @($byTag.Keys)) {
    $m = $meta[$tag]
    if (-not $m) { throw "Downloaded artifacts for tag '$tag' but the decision for this run does not mention it" }

    $platformList = (@($byTag[$tag].platforms | Select-Object -Unique)) -join ', '
    Write-Host ("Publishing " + $tag + " (" + $platformList + ")")

    $stage = Join-Path $PWD ("stage-" + $tag)
    New-Item -ItemType Directory -Force -Path $stage | Out-Null

    # 1. the patch bundle - identical in spirit to what the release notes
    #    describe: the kit's patch files, concatenated, one file per release
    $patchDir = Join-Path $repoRoot 'patches'
    $patchFiles = @(Get-ChildItem $patchDir -Filter '*.patch' | Sort-Object Name)
    if ($patchFiles.Count -eq 0) { throw "No patch files found under patches/" }
    $sb = New-Object System.Text.StringBuilder
    foreach ($p in $patchFiles) {
        [void]$sb.AppendLine(("# ---- upstream tag " + $tag + ", patch file " + $p.Name + " ----"))
        [void]$sb.Append([IO.File]::ReadAllText($p.FullName))
        [void]$sb.AppendLine("")
    }
    $patchPath = Join-Path $stage ("source-patches-" + $tag + ".patch")
    [IO.File]::WriteAllText($patchPath, $sb.ToString(), $utf8)

    # 2. checksums over every published file, built binaries included
    $assets = @()
    foreach ($f in @($byTag[$tag].files | Sort-Object Name)) {
        $assets += $f.FullName
    }
    $assets += $patchPath

    $lines = @()
    $seenNames = @{}
    foreach ($f in $assets) {
        $name = [IO.Path]::GetFileName($f)
        if ($seenNames.ContainsKey($name)) { throw ("Duplicate asset name '" + $name + "' for " + $tag) }
        $seenNames[$name] = $true
        $h = (Get-FileHash $f -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines += ("SHA256  " + $h + "  " + $name)
    }
    $checksumsPath = Join-Path $stage 'checksums.txt'
    [IO.File]::WriteAllText($checksumsPath, (($lines -join "`r`n") + "`r`n"), $utf8)

    # 3. release notes from the kit template
    $tmplFile = Join-Path (Join-Path $repoRoot 'docs') 'release-notes-template.md'
    $tmpl = [IO.File]::ReadAllText($tmplFile)
    $tmpl = $tmpl.Replace('{{TAG}}', $tag).Replace('{{UPSTREAM_URL}}', "https://github.com/PrismLauncher/PrismLauncher/releases/tag/$tag")
    $notesPath = Join-Path $stage 'release-notes.md'
    [IO.File]::WriteAllText($notesPath, $tmpl, $utf8)

    # 4. the release itself: create, overwrite on force, refresh otherwise
    $exists = $false
    # (Deliberately no 2>$null on the gh call: under ErrorActionPreference
    # 'Stop' an in-script stderr redirect turns native stderr into a
    # terminating NativeCommandError on Windows PowerShell 5.1 - the same
    # trap already fixed once each in sync-kit.ps1 and notify-kit-update.ps1.)
    try {
        gh release view $tag --json tagName | Out-Null
        if ($LASTEXITCODE -eq 0) { $exists = $true }
    }
    catch { }

    if ($exists -and $m.force) {
        Write-Host ("Overwriting existing release " + $tag)
        gh release delete $tag --yes --cleanup-tag
        if ($LASTEXITCODE -ne 0) { throw ("Could not delete release " + $tag) }
        $exists = $false
    }

    $uploadList = @($assets + $checksumsPath)
    if ($exists) {
        Write-Host ("Release " + $tag + " already exists; refreshing its files.")
        gh release upload $tag @uploadList --clobber
        if ($LASTEXITCODE -ne 0) { throw ("gh release upload failed for " + $tag) }
        gh release edit $tag --notes-file $notesPath
        if ($LASTEXITCODE -ne 0) { throw ("gh release edit failed for " + $tag) }
    }
    else {
        $extra = @()
        if ($m.prerelease) { $extra += '--prerelease' } else { $extra += '--latest' }
        $createArgs = @($tag) + $uploadList + @(
            '--title', ("Prism Launcher " + $tag + " (offline-patched)"),
            '--notes-file', $notesPath
        ) + $extra
        gh @createArgs
        if ($LASTEXITCODE -ne 0) { throw ("gh release create failed for " + $tag) }
    }

    # Prove the release really exists in this repository before going green.
    gh release view $tag --json tagName,isDraft | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ("Release " + $tag + " is not visible in this repository after publish") }

    Write-Host ("Published release " + $tag)
}
