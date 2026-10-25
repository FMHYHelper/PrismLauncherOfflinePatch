# Decides what this run should build. Writes a "builds=<json>" entry that the
# workflow turns into a job matrix. See README.md for the policy.
#
#   - On scheduled/default runs: newest unhandled upstream stable tag, plus the
#     newest upstream pre-release tag but only when it outranks the stable
#     baseline. Stable sorts before pre so a stable is attempted first.
#   - With -UpstreamRef: exactly that ref (branch or tag), state untouched.
#   - With -Force: rebuild even if a release for the tag already exists here.
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
$builds = New-Object System.Collections.ArrayList

function Add-Candidate {
    param($Tag, [bool]$IsPre, [string]$QtVersion, [string]$QtArch, [string]$Vcvars, [string]$Preset, [bool]$BypassExists)

    if (-not $BypassExists -and ($ourTags -contains $Tag)) {
        Write-Host "Release for $Tag already exists here; skipping."
        return
    }
    [void]$script:builds.Add([pscustomobject]@{
        tag        = $Tag
        prerelease = $IsPre
        qt_version = $QtVersion
        qt_arch    = $QtArch
        vcvars     = $Vcvars
        preset     = $Preset
        force      = $BypassExists
    })
}

if ($UpstreamRef) {
    # manual one-off build of an explicit upstream ref
    $flag = $false
    $manualEntry = $published | Where-Object { [string]$_.tag_name -eq $UpstreamRef } | Select-Object -First 1
    if ($manualEntry) { $flag = [bool]$manualEntry.prerelease }

    $recipe = Get-UpstreamWindowsRecipe -Ref $UpstreamRef -Token $token
    $qt = if ($QtOverride) { $QtOverride } else { $recipe.qt_version }
    Add-Candidate -Tag $UpstreamRef -IsPre $flag -QtVersion $qt -QtArch $recipe.qt_arch -Vcvars $recipe.vcvars -Preset $recipe.preset -BypassExists ([bool]$Force)
    Write-Host ("Manual ref requested: " + $UpstreamRef + " (prerelease=" + $flag + ", qt=" + $qt + ")")
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
        $recipe = Get-UpstreamWindowsRecipe -Ref $newestStable.tag -Token $token
        $qt = if ($QtOverride) { $QtOverride } else { $recipe.qt_version }
        if ($needsStableBuild) {
            if ($isNew) {
                Write-Host ("New stable release: " + $newestStable.tag)
            }
            else {
                Write-Host ("State marks " + $newestStable.tag + " as handled, but no release for it exists here; rebuilding.")
            }
            Add-Candidate -Tag $newestStable.tag -IsPre $false -QtVersion $qt -QtArch $recipe.qt_arch -Vcvars $recipe.vcvars -Preset $recipe.preset -BypassExists ([bool]$Force)
        }
        elseif ($hashChanged) {
            Write-Host ("Patch set or recipe changed; offering a rebuild of " + $newestStable.tag)
            Add-Candidate -Tag $newestStable.tag -IsPre $false -QtVersion $qt -QtArch $recipe.qt_arch -Vcvars $recipe.vcvars -Preset $recipe.preset -BypassExists ([bool]$Force)
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
                # A pre-release is optional: if its build recipe cannot be read
                # (missing file, transient upstream change), skip it and let the
                # next daily run retry. This must never block the stable build.
                $preRecipe = $null
                try {
                    $preRecipe = Get-UpstreamWindowsRecipe -Ref $newestPre.tag -Token $token
                }
                catch {
                    Write-Warning ("Could not read the build recipe for pre-release " + $newestPre.tag + " (" + $_.Exception.Message + "); skipping it this run.")
                }
                if ($preRecipe) {
                    $preQt = if ($QtOverride) { $QtOverride } else { $preRecipe.qt_version }
                    Add-Candidate -Tag $newestPre.tag -IsPre ([bool]$preEntry.pre) -QtVersion $preQt -QtArch $preRecipe.qt_arch -Vcvars $preRecipe.vcvars -Preset $preRecipe.preset -BypassExists ([bool]$Force)
                }
            }
        }
    }
    elseif (($newestPre) -and ($null -eq $handledStableVer)) {
        # upstream only has pre-releases so far
        $preEntry = $known | Where-Object { $_.tag -eq $newestPre.tag } | Select-Object -First 1
        $preRecipe = $null
        try {
            $preRecipe = Get-UpstreamWindowsRecipe -Ref $newestPre.tag -Token $token
        }
        catch {
            Write-Warning ("Could not read the build recipe for pre-release " + $newestPre.tag + " (" + $_.Exception.Message + "); skipping it this run.")
        }
        if ($preRecipe) {
            Write-Host ("No stable releases yet; offering " + $newestPre.tag)
            $preQt = if ($QtOverride) { $QtOverride } else { $preRecipe.qt_version }
            Add-Candidate -Tag $newestPre.tag -IsPre ([bool]$preEntry.pre) -QtVersion $preQt -QtArch $preRecipe.qt_arch -Vcvars $preRecipe.vcvars -Preset $preRecipe.preset -BypassExists ([bool]$Force)
        }
    }
    elseif (-not $newestStable) {
        Write-Warning 'No parseable upstream releases found.'
    }
}

# --------------------------------------------------------------- output ----
# stable first, then pre; cap the work per run
$ordered = @() + @($builds | Where-Object { -not $_.prerelease }) + @($builds | Where-Object { $_.prerelease })
if ($ordered.Count -gt $MaxBuilds) {
    Write-Host ("Capping run at the first $MaxBuilds builds of " + $ordered.Count)
    $ordered = $ordered[0..($MaxBuilds - 1)]
}

$js = @{ include = @($ordered) } | ConvertTo-Json -Compress -Depth 5
# The workflow file cannot call length() on the include array (no such
# expression function exists), so the decision script publishes the boolean
# gate itself.
$hasBuilds = if (@($ordered).Count -gt 0) { 'true' } else { 'false' }

if ($OutputFile) {
    Add-Content -Path $OutputFile -Value "builds=$js"
    Add-Content -Path $OutputFile -Value "has_builds=$hasBuilds"
}
Write-Output "builds=$js"
Write-Output "has_builds=$hasBuilds"
Write-Host ("Kit identity hash: " + $kitHash)
