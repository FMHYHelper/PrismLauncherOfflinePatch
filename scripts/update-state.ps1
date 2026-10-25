# Merges the outcome of a run into .state/last-build.json and always refreshes
# the heartbeat timestamp. Called by the workflow's final job.
#
#   Advance: the whole build matrix succeeded; fold the built tags into the
#            handled states so they are not rebuilt next run.
#   Otherwise: only the heartbeat (last_checked) and the current kit identity
#            hash are refreshed.
#
# Note: callers should always call this even for heartbeat-only runs, since the
# resulting state-file commit is what keeps GitHub from disabling the schedule
# on quiet repos.

param(
    [string]$BuildsJson = '[]',
    [switch]$Advance
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$repoRoot = Find-RepoRoot
$statePath = Join-Path $repoRoot '.state\last-build.json'
New-Item -ItemType Directory -Force -Path (Split-Path $statePath) | Out-Null

$state = [pscustomobject]@{
    handled_stable = ''
    handled_pre    = ''
    patches_hash   = ''
    last_checked   = ''
}
if (Test-Path $statePath) {
    $state = Get-Content $statePath -Raw | ConvertFrom-Json
    foreach ($k in @('handled_stable', 'handled_pre', 'patches_hash', 'last_checked')) {
        if (-not ($state.PSObject.Properties[$k])) {
            Add-Member -InputObject $state -NotePropertyName $k -NotePropertyValue '' -Force
        }
    }
}

if ($Advance) {
    # NB: under Windows PowerShell 5.1, ConvertFrom-Json deserializes an empty
    # "include" array as $null, so guard before iterating.
    $parsed = $BuildsJson | ConvertFrom-Json
    if ($parsed.include) {
        foreach ($e in @($parsed.include)) {
        $v = ConvertFrom-PrismTag ([string]$e.tag)
        if ($null -eq $v) {
            Write-Host ("Tag " + $e.tag + " is not a version tag; not recorded in handled state.")
            continue
        }
        if (-not $e.prerelease) {
            $cur = ConvertFrom-PrismTag $state.handled_stable
            if ((-not $cur) -or ((Compare-PrismTag $v $cur) -gt 0)) { $state.handled_stable = [string]$e.tag }
        }
        else {
            $cur = ConvertFrom-PrismTag $state.handled_pre
            if ((-not $cur) -or ((Compare-PrismTag $v $cur) -gt 0)) { $state.handled_pre = [string]$e.tag }
        }
        }
    }
}

$state.patches_hash = Get-KitIdentityHash -Root $repoRoot
$state.last_checked = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

$state | ConvertTo-Json -Depth 4 | Set-Content -Path $statePath -NoNewline
Write-Output ("state-written: " + $statePath)
if ($Advance) {
    Write-Output ("advance: ok (stable=" + $state.handled_stable + ", pre=" + $state.handled_pre + ")")
}
