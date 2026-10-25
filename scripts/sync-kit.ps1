# sync-kit.ps1
#
# Takes the template's update on behalf of the user. Invoked by the
# sync-from-template workflow (manual "Run workflow" button only - this
# changes the repository, so it never runs automatically).
#
# Behavior:
#   - refuses silently when this repository IS the template
#   - compares this copy's KIT-VERSION against the template's
#   - behind: replaces the kit paths (same list, same overlay semantics as
#     the "Template update available" issue: template files are refreshed,
#     everything else in this repository is untouched), commits as
#     github-actions[bot], pushes, and then closes EVERY open
#     "Template update available" issue as completed (they are all stale
#     the moment the push lands - the next build run would close them too,
#     but there is no reason to leave them open for a day)
#   - already in step: says so, pushes nothing, and still closes any open
#     nudge issues (they are stale in that case as well)
#
# Unlike the nudge check this is a deliberate user action, so failures are
# loud: they turn the run red with an explanatory error instead of a
# warning. The one soft spot is a push raced by the build workflow's state
# heartbeat - that retries once with pull --rebase (the same rescue the
# issue text gives to manual terminal users) before giving up. Closing
# issues is always best effort: a closed-copy failure in the middle of an
# otherwise successful sync is a warning, not an error.

$ErrorActionPreference = 'Stop'

$template = if ($env:TEMPLATE_SOURCE) { $env:TEMPLATE_SOURCE } else { 'FMHYHelper/PrismLauncherOfflinePatch' }
$issueTitle = 'Template update available'
$summaryFile = $env:GITHUB_STEP_SUMMARY

function Add-SummaryLine {
  param([string]$Text)
  if ($summaryFile) {
    try { Add-Content -Path $summaryFile -Value $Text } catch { }
  }
}

function Get-OpenNudgeIssues {
  # Returns all open issues titled exactly like the update nudge (a copy
  # can legitimately have more than one: filed before an earlier sync was
  # taken by hand, or kept open because the closing run had not happened).
  # Best effort by contract: gh trouble (token, rate limit) means "nothing
  # measurable", never an error - this runs even after the sync has landed.
  #
  # (Deliberately no 2>$null on the gh call: under ErrorActionPreference
  # 'Stop' an in-script stderr redirect turns native stderr into a
  # terminating NativeCommandError - seen for real with git remote add -
  # which would go red on a run that already succeeded.)
  try {
    $raw = gh issue list --state open --json number,title
    if ($LASTEXITCODE -ne 0) { return @() }
    if ([string]::IsNullOrWhiteSpace("$raw")) { return @() }
    return @(ConvertFrom-Json ([string]$raw) | Where-Object { $_.title -ceq $issueTitle })
  }
  catch {
    return @()
  }
}

function Close-NudgeIssues {
  # Best effort: closes every open nudge issue with a dated note. Failures
  # never fail the sync - the next build run's check closes what remains.
  param([string]$Note)
  $day = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
  foreach ($issue in (Get-OpenNudgeIssues)) {
    try {
      gh issue close $issue.number --reason completed --comment ("$Note (UTC $day)")
      if ($LASTEXITCODE -eq 0) {
        Write-Host "Closed nudge issue #$($issue.number)."
      } else {
        Write-Host "::warning::Could not close nudge issue #$($issue.number); the next build run's check will close it."
      }
    }
    catch {
      Write-Host "::warning::Could not close nudge issue #$($issue.number); the next build run's check will close it."
    }
  }
}

# ---- refuse to sync the template with itself --------------------------------
if ($env:GITHUB_REPOSITORY -and ($env:GITHUB_REPOSITORY -eq $template)) {
  Write-Host "This repository is the template; nothing to sync."
  exit 0
}

# ---- local and template versions ---------------------------------------------
$localVersion = '0'
if (Test-Path 'KIT-VERSION') {
  $localVersion = ([string](Get-Content 'KIT-VERSION' -Raw)).Trim()
  if (-not $localVersion) { $localVersion = '0' }
}

$templateUrl = $template
if (-not $template.StartsWith('http')) {
  if (Test-Path $template) {
    # a real local path: dev/testing convenience (owner/name never resolves
    # to a filesystem path, so this branch cannot trigger on the runner)
    $templateUrl = $template
  }
  else {
    $templateUrl = "https://github.com/$template.git"
  }
}

$remotes = @(git remote)
if ($remotes -contains 'template') {
  git remote set-url template "$templateUrl"
  if ($LASTEXITCODE -ne 0) { throw "Could not point the 'template' remote at $templateUrl" }
}
else {
  git remote add template "$templateUrl"
  if ($LASTEXITCODE -ne 0) { throw "Could not add the 'template' remote at $templateUrl" }
}
git fetch --quiet template main
if ($LASTEXITCODE -ne 0) { throw "Could not fetch the template ($template)" }
$templateVersion = (([string](git show template/main:KIT-VERSION))).Trim()
if ($LASTEXITCODE -ne 0 -or -not $templateVersion) { throw "The template has no readable KIT-VERSION" }

Write-Host "KIT-VERSION check: template '$templateVersion' / this copy '$localVersion'"

if ([int]$templateVersion -le [int]$localVersion) {
  Write-Host "Already in step (template $templateVersion <= copy $localVersion); nothing to sync."
  Close-NudgeIssues -Note "Kit is already in step (kit version $localVersion, matching the template), so any open update-notice here was stale and is closed."
  Add-SummaryLine "Kit sync: already in step (kit **$localVersion**)."
  exit 0
}

# ---- replace the kit paths (overlay: nothing else is removed) ----------------
$kitPaths = @('.github/workflows', 'README.md', 'MAINTAINING.md', 'KIT-VERSION', 'docs', 'patches', 'scripts')
foreach ($p in $kitPaths) {
  git checkout template/main -- $p
  if ($LASTEXITCODE -ne 0) { throw "Could not take '$p' from the template" }
}
git diff --cached --quiet
if ($LASTEXITCODE -eq 0) { throw "The template is ahead but the checkout produced no changes; please report this at the template" }

# ---- commit for the record, as the neutral automation identity ---------------
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git commit -m "Sync kit files from template (kit version $templateVersion)"
if ($LASTEXITCODE -ne 0) { throw "Could not commit the synced kit files" }

# ---- push (heartbeat race: one automatic pull --rebase, then admit defeat) ----
$branch = if ($env:GITHUB_REF_NAME) { $env:GITHUB_REF_NAME } else { 'main' }
git push origin "HEAD:$branch"
if ($LASTEXITCODE -ne 0) {
  Write-Host "Push raced another run (likely the state heartbeat); retrying once with pull --rebase - the same rescue the nudge issue gives to terminal users."
  git pull --rebase origin "$branch"
  if ($LASTEXITCODE -ne 0) { throw "Could not rebase onto $branch (a concurrent run may still be pushing); rerun this workflow in a minute" }
  git push origin "HEAD:$branch"
  if ($LASTEXITCODE -ne 0) { throw "Push to $branch failed after the retry; rerun this workflow in a minute" }
}

Write-Host "Synced to the template: kit version $templateVersion."
Add-SummaryLine "Kit sync: **$localVersion -> $templateVersion** - committed and pushed. The next build run will use the new kit files."

# ---- close the open update issues (best effort, never fails the sync) --------
Close-NudgeIssues -Note "The sync was taken from the template (kit version $templateVersion is now in this repository), so every open update-notice here is closed. The next build run will already use the new kit files."

exit 0
