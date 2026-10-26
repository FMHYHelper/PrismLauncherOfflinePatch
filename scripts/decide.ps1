# Decides what this run should build. Writes a "builds=<json>" entry that the
# workflow turns into a job matrix - one job per (tag, platform) pair. See
# README.md for the policy.
#
#   - On scheduled/default runs: newest unhandled upstream stable tag, plus the
#     newest upstream pre-release tag but only when it outranks the stable
#     baseline. Stable sorts before pre so a stable is attempted first.
#     Every selected tag is offered for each enabled platform: Windows (MSVC)
#     for the drop-in exe and portable zip, Linux (x86_64) for the AppImage
#     and portable tarball, and macOS (universal) for the DMG.
#   - With -UpstreamRef: exactly that ref (branch or tag), state untouched.
#   - With -Force: rebuild even if a release for the tag already exists here.
#   - KIT_PLATFORMS (the repositories variable `platforms`) filters the
#     platform list: comma or space separated subset of windows,linux,macos;
#     empty or 'all' means all of them.
#   - Kit-age gate (kit 12): when this copy's KIT-VERSION is behind the
#     template's, nothing is built at all - has_builds=false, plus a loud
#     "BUILDS SKIPPED" banner in the log, a warning annotation and a run
#     summary line. An old kit must never build or publish. Fail-open by
#     contract: only a positive, parsed comparison (both versions integers,
#     local < remote) skips a run; network trouble or parse trouble builds
#     as before. The template itself never gates (it defines "current"),
#     and the repository variable build_if_old=true is the emergency bypass.
#
# Per-platform recipes come from the upstream tag's own CI configuration.
# Strictness when a recipe cannot be read:
#   - Windows on a stable or manually requested ref: fatal. Building nothing
#     is better than publishing something half-defined.
#   - Windows on a pre-release: skip the pre-release, never block the stable.
#   - Linux/macOS anywhere: skip that platform with a warning; the other
#     platforms still build. Upstream may restructure its Linux/macOS CI at
#     any time, and that must not cost a copy its Windows exe.
#
# Runs on any Windows PowerShell 5.1+ or pwsh, including Linux runners.

param(
    [string]$UpstreamRef = '',
    [string]$QtOverride = '',
    [switch]$Force,
    [string]$OutputFile = '',
    [int]$MaxBuilds = 2
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$repoRoot = Find-RepoRoot
$statePath = Join-Path $repoRoot '.state\last-build.json'

# ------------------------------------------------------ kit freshness ----
# Kit 12: a copy whose kit is behind the template must not build at all -
# building (and publishing) from an old kit wasted whole runs and could
# publish releases with outdated kit logic. Fail-open on purpose: only a
# positive, parsed comparison skips the run; a failed template fetch or an
# unparseable KIT-VERSION builds as before (the nudge issue keeps nagging
# either way). Test hooks, mirroring KIT_TEST_RELEASES_FILE:
#   KIT_TEST_TEMPLATE_KIT_VERSION - stand-in for the template's version;
#   keeps the gate ON offline (while KIT_TEST_RELEASES_FILE alone - the
#   older batteries - bypasses the gate)
#   KIT_BUILD_IF_OLD - from the repository variable build_if_old; the
#   documented emergency bypass.
function Test-KitBehind {
    # Returns 'skip' when this copy is positively known to be behind the
    # template, 'ok' when it is in step or ahead, 'unknown' when no fair
    # comparison was possible. Prints the loud block for the 'skip' case.
    param([string]$LocalFile, [string]$RemoteVersion)

    $localKit = ''
    if (Test-Path $LocalFile) { $localKit = ([string](Get-Content $LocalFile -Raw)).Trim() }
    $localNum = 0
    $remoteNum = 0
    $localOk = [int]::TryParse($localKit, [ref]$localNum)
    $remoteOk = [int]::TryParse("$RemoteVersion", [ref]$remoteNum)

    if (-not ($localOk -and $remoteOk)) {
        Write-Host ("Kit freshness check could not compare versions (this copy '{0}', template '{1}'); building as usual." -f $localKit, $RemoteVersion)
        return 'unknown'
    }
    if ($localNum -ge $remoteNum) {
        Write-Host ("Kit freshness check: this copy {0} / template {1} - in step or ahead, building." -f $localNum, $remoteNum)
        return 'ok'
    }

    Write-Host "================================================================="
    Write-Host "  BUILDS SKIPPED: THIS COPY'S KIT IS OUT OF DATE"
    Write-Host ""
    Write-Host ("  This copy is at kit {0}; the template is at kit {1}." -f $localNum, $remoteNum)
    Write-Host "  The build was skipped on purpose - an old kit must never"
    Write-Host "  build or publish. Nothing is broken. Fix it in two steps:"
    Write-Host ""
    Write-Host "    1. Actions tab -> 'Sync kit files from template' -> Run workflow"
    Write-Host "       (needs the one-time KIT_PUSH_TOKEN secret; the issue titled"
    Write-Host "       'Template update available' has the full setup steps and a"
    Write-Host "       terminal route that needs no token)"
    Write-Host "    2. Actions tab -> 'Build patched Prism Launcher' -> Run workflow"
    Write-Host ""
    Write-Host "================================================================="
    Write-Host ("::warning::Builds skipped: kit out of date (this copy kit {0}, template kit {1}). Sync the kit, then run again." -f $localNum, $remoteNum)
    if ($env:GITHUB_STEP_SUMMARY) {
        try {
            Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ("## Builds skipped: kit out of date`n`nThis copy is at kit **{0}**; the template is at kit **{1}**. Sync first (Actions > 'Sync kit files from template'), then run 'Build patched Prism Launcher' again." -f $localNum, $remoteNum)
        } catch { }
    }
    return 'skip'
}

$kitOldSkip = $false
if ($env:KIT_BUILD_IF_OLD -eq 'true') {
    Write-Host "Repository variable build_if_old is set; the kit-age gate is bypassed for this run."
}
elseif ($env:GITHUB_REPOSITORY -and $env:TEMPLATE_SOURCE -and ($env:GITHUB_REPOSITORY -eq $env:TEMPLATE_SOURCE)) {
    Write-Host "This repository is the template itself; the kit-age gate does not apply."
}
elseif ($env:KIT_TEST_TEMPLATE_KIT_VERSION) {
    Write-Host "Test mode (KIT_TEST_TEMPLATE_KIT_VERSION); the gate compares against '$($env:KIT_TEST_TEMPLATE_KIT_VERSION)' without fetching."
    $kitOldSkip = Test-KitBehind -LocalFile (Join-Path $repoRoot 'KIT-VERSION') -RemoteVersion $env:KIT_TEST_TEMPLATE_KIT_VERSION
}
elseif ($env:KIT_TEST_RELEASES_FILE) {
    Write-Host "Test mode (KIT_TEST_RELEASES_FILE); the kit-age gate is bypassed."
}
else {
    $templateRepo = if ($env:TEMPLATE_SOURCE) { $env:TEMPLATE_SOURCE } else { 'FMHYHelper/PrismLauncherOfflinePatch' }
    $remoteKit = ''
    try {
        $remoteKit = ([string](Invoke-RestMethod "https://raw.githubusercontent.com/$templateRepo/main/KIT-VERSION")).Trim()
    }
    catch {
        Write-Host "::warning::Could not read the template's KIT-VERSION ($($_.Exception.Message)); the kit-age gate cannot run, so this run builds as usual."
    }
    $kitOldSkip = Test-KitBehind -LocalFile (Join-Path $repoRoot 'KIT-VERSION') -RemoteVersion $remoteKit
}

if ($kitOldSkip -eq 'skip') {
    # Same output shape as the normal tail: empty matrix, no builds.
    $js = @{ include = @() } | ConvertTo-Json -Compress -Depth 5
    if ($OutputFile) {
        Add-Content -Path $OutputFile -Value "builds=$js"
        Add-Content -Path $OutputFile -Value "has_builds=false"
    }
    Write-Output "builds=$js"
    Write-Output "has_builds=false"
    exit 0
}

# ---------------------------------------------------------------- state ----
$state = [pscustomobject]@{
    handled_stable = ''
    handled_pre    = ''
    patches_hash   = ''
    last_checked   = ''
}
if (Test-Path $statePath) {
    $state = Get-Content $statePath -Raw | ConvertFrom-Json
    foreach ($k in @('handled_stable', 'handled_pre', 'patches_hash')) {
        if (-not ($state.PSObject.Properties[$k])) {
            Add-Member -InputObject $state -NotePropertyName $k -NotePropertyValue '' -Force
        }
    }
}

$kitHash = Get-KitIdentityHash -Root $repoRoot
$hashChanged = ($state.patches_hash -ne $kitHash)

# ------------------------------------------------------------- upstream ----
$token = $env:GITHUB_TOKEN
$headers = Get-UpstreamApiHeaders -Token $token

$upstreamReleases = @()
if ($env:KIT_TEST_RELEASES_FILE) {
    $upstreamReleases = Get-Content $env:KIT_TEST_RELEASES_FILE -Raw | ConvertFrom-Json
}
else {
    $upstreamReleases = Invoke-RestMethod -Uri 'https://api.github.com/repos/PrismLauncher/PrismLauncher/releases?per_page=50' -Headers $headers
}

$published = @($upstreamReleases | Where-Object { -not $_.draft })

$known = New-Object System.Collections.ArrayList
$skipped = New-Object System.Collections.ArrayList
foreach ($rel in $published) {
    $v = ConvertFrom-PrismTag $rel.tag_name
    if ($null -eq $v) {
        [void]$skipped.Add($rel.tag_name)
        continue
    }
    [void]$known.Add([pscustomobject]@{
        tag = [string]$rel.tag_name
        ver = $v
        pre = [bool]$rel.prerelease
    })
}
if ($skipped.Count) {
    Write-Host ("Tags ignored (not simple release versions): " + ($skipped -join ', '))
}

$stableList = @($known | Where-Object { -not $_.pre })
$preList    = @($known | Where-Object { $_.pre })
$newestStable = Get-MaxPrismTag $stableList
$newestPre    = Get-MaxPrismTag $preList

# ------------------------------------------------------------- our tags ----
$ourTags = @()
if (-not $env:KIT_TEST_RELEASES_FILE -and $env:GITHUB_REPOSITORY) {
    $apiBase = if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL } else { 'https://api.github.com' }
    try {
        $ours = Invoke-RestMethod -Uri "$apiBase/repos/$env:GITHUB_REPOSITORY/releases?per_page=50" -Headers $headers
        $ourTags = @($ours | ForEach-Object { [string]$_.tag_name })
    }
    catch {
        Write-Warning "Could not read this repo's releases: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------ candidates ----
$handledStableVer = ConvertFrom-PrismTag $state.handled_stable
$handledPreVer    = ConvertFrom-PrismTag $state.handled_pre
$candidates = New-Object System.Collections.ArrayList

function Add-Candidate {
    param($Tag, [bool]$IsPre, [bool]$BypassExists)

    if (-not $BypassExists -and ($ourTags -contains $Tag)) {
        Write-Host "Release for $Tag already exists here; skipping."
        return
    }
    [void]$script:candidates.Add([pscustomobject]@{
        tag   = $Tag
        pre   = $IsPre
        force = $BypassExists
    })
}

if ($UpstreamRef) {
    # manual one-off build of an explicit upstream ref
    $flag = $false
    $manualEntry = $published | Where-Object { [string]$_.tag_name -eq $UpstreamRef } | Select-Object -First 1
    if ($manualEntry) { $flag = [bool]$manualEntry.prerelease }

    Add-Candidate -Tag $UpstreamRef -IsPre $flag -BypassExists ([bool]$Force)
    Write-Host ("Manual ref requested: " + $UpstreamRef + " (prerelease=" + $flag + ")")
}
else {
    if ($newestStable) {
        $isNew = ($null -eq $handledStableVer) -or ((Compare-PrismTag $newestStable.ver $handledStableVer) -gt 0)
        # State/parity guard: repositories created from this template inherit
        # the template's state file, which may claim tags as handled even
        # where the copy never published anything. In a publishing
        # repository (PRISM_PUBLISH=true, set by the workflow), a tag only
        # counts as handled if this repo actually has a release for it.
        # Pre-releases keep the simple state rule; they are optional anyway.
        $publishes = ($env:PRISM_PUBLISH -eq 'true')
        $stableReleaseMissing = ($ourTags -notcontains $newestStable.tag)
        $needsStableBuild = $isNew -or ($publishes -and $stableReleaseMissing)
        if ($needsStableBuild) {
            if ($isNew) {
                Write-Host ("New stable release: " + $newestStable.tag)
            }
            else {
                Write-Host ("State marks " + $newestStable.tag + " as handled, but no release for it exists here; rebuilding.")
            }
            Add-Candidate -Tag $newestStable.tag -IsPre $false -BypassExists ([bool]$Force)
        }
        elseif ($hashChanged) {
            Write-Host ("Patch set or recipe changed; offering a rebuild of " + $newestStable.tag)
            Add-Candidate -Tag $newestStable.tag -IsPre $false -BypassExists ([bool]$Force)
        }
        else {
            Write-Host ("Stable " + $newestStable.tag + " already handled.")
        }

        $baseline = $handledStableVer
        if ($isNew) { $baseline = $newestStable.ver }

        if ($newestPre) {
            $preNew = ($null -eq $baseline) -or ((Compare-PrismTag $newestPre.ver $baseline) -gt 0)
            $alreadyHandled = ($null -ne $handledPreVer) -and ((Compare-PrismTag $newestPre.ver $handledPreVer) -le 0)
            if ($preNew -and -not $alreadyHandled) {
                Write-Host ("New pre-release that outranks the stable baseline: " + $newestPre.tag)
                $preEntry = $known | Where-Object { $_.tag -eq $newestPre.tag } | Select-Object -First 1
                Add-Candidate -Tag $newestPre.tag -IsPre ([bool]$preEntry.pre) -BypassExists ([bool]$Force)
            }
        }
    }
    elseif (($newestPre) -and ($null -eq $handledStableVer)) {
        # upstream only has pre-releases so far
        $preEntry = $known | Where-Object { $_.tag -eq $newestPre.tag } | Select-Object -First 1
        Write-Host ("No stable releases yet; offering " + $newestPre.tag)
        Add-Candidate -Tag $newestPre.tag -IsPre ([bool]$preEntry.pre) -BypassExists ([bool]$Force)
    }
    elseif (-not $newestStable) {
        Write-Warning 'No parseable upstream releases found.'
    }
}

# ------------------------------------------------------------ ordering ----
# stable first, then pre; cap the work per run at tag level (each selected tag
# expands into one build per enabled platform below)
$orderedTags = @() + @($candidates | Where-Object { -not $_.pre }) + @($candidates | Where-Object { $_.pre })
if ($orderedTags.Count -gt $MaxBuilds) {
    Write-Host ("Capping run at the first $MaxBuilds builds of " + $orderedTags.Count)
    $orderedTags = $orderedTags[0..($MaxBuilds - 1)]
}

# ---------------------------------------------------------- platforms ----
$platforms = Resolve-KitPlatforms -Spec $env:KIT_PLATFORMS
if ($orderedTags.Count) {
    Write-Host ("Platforms this run: " + ($platforms -join ', '))
}

$entries = New-Object System.Collections.ArrayList
foreach ($c in @($orderedTags)) {
    foreach ($p in $platforms) {
        try {
            $r = Get-UpstreamPlatformRecipe -Ref $c.tag -Platform $p -Token $token
        }
        catch {
            if (($p -eq 'windows') -and (-not $c.pre)) { throw }
            Write-Warning ("No recipe for " + $p + " at " + $c.tag + " (" + $_.Exception.Message + "); skipping it this run.")
            continue
        }
        $qt = if ($QtOverride) { $QtOverride } else { $r.qt_version }
        [void]$entries.Add([pscustomobject]@{
            tag           = $c.tag
            prerelease    = [bool]$c.pre
            force         = [bool]$c.force
            platform      = $p
            os            = $r.os
            artifact_name = $r.artifact_name
            preset        = $r.preset
            qt_version    = $qt
            vcvars        = $r.vcvars
            qt_arch       = $r.qt_arch
            macosx_target = $r.macosx_target
        })
    }
}

# --------------------------------------------------------------- output ----
$js = @{ include = @($entries) } | ConvertTo-Json -Compress -Depth 5
# The workflow file cannot call length() on the include array (no such
# expression function exists), so the decision script publishes the boolean
# gate itself.
$hasBuilds = if (@($entries).Count -gt 0) { 'true' } else { 'false' }

if ($OutputFile) {
    Add-Content -Path $OutputFile -Value "builds=$js"
    Add-Content -Path $OutputFile -Value "has_builds=$hasBuilds"
}
Write-Output "builds=$js"
Write-Output "has_builds=$hasBuilds"
Write-Host ("Kit identity hash: " + $kitHash)
