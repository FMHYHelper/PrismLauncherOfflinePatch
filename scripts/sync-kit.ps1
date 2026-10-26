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
# warning. Push refusals come in two opposite classes, and kit 10 teaches
# the script to tell them apart:
#   - a race (transient): the build workflow's state heartbeat landed a
#     commit first - retried once with pull --rebase (the same rescue the
#     issue text gives to manual terminal users);
#   - GitHub's workflow-file rule (permanent): pushes that change files
#     under .github/workflows cannot be made by the default GITHUB_TOKEN -
#     the "workflows" permission is not grantable to that token at all,
#     and kit syncs always carry workflow files. Never retried; fails
#     loudly with the one-time setup steps for the KIT_PUSH_TOKEN secret
#     (a fine-grained personal access token), which - when it exists -
#     this script uses for the push alone (token-in-URL, never stored,
#     never logged). Copies still on kit 9 or older first reach kit 10 by
#     the terminal route in the nudge issue: their button predates this
#     logic.
# Closing issues is always best effort: a closed-copy failure in the middle
# of an otherwise successful sync is a warning, not an error.

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

# ---- push: two refusal classes, opposite handling ------------------------------
$branch = if ($env:GITHUB_REF_NAME) { $env:GITHUB_REF_NAME } else { 'main' }

# The optional personal token: used for the push only, and only when this
# checkout is a github.com https remote (local file-path origins - the
# development and dry-run rigs - keep the ordinary push, so the rig stays
# representative and nothing network-bound can ever run there).
$kitPushUrl = $null
$kitToken = $env:KIT_PUSH_TOKEN
if ($kitToken) {
  $originUrl = ''
  try {
    $originUrl = ([string](git remote get-url origin)).Trim()
    if ($LASTEXITCODE -ne 0) { $originUrl = '' }
  }
  catch { $originUrl = '' }
  if ($originUrl -cmatch '^https://(www\.)?github\.com/') {
    $kitPushUrl = 'https://x-access-token:' + $kitToken + '@' + ($originUrl -creplace '^https://', '')
    Write-Host 'Pushing with the KIT_PUSH_TOKEN credential (GitHub requires it for pushes that change workflow files).'
  }
  else {
    Write-Host 'KIT_PUSH_TOKEN is set, but origin is not a github.com https URL (a local or dry-run repository); pushing normally.'
  }
}

$PSNativeCommandUseErrorActionPreference = $false

$script:kitHeaderBackup = @()

function Clear-KitCheckoutAuth {
  # actions/checkout stores the automatic bot token as repo-local config
  # http.<url>.extraheader. That header matches EVERY https://github.com URL -
  # including the token-in-URL push URL - and its Authorization value wins over
  # the URL's own credentials, so a KIT_PUSH_TOKEN push would go out wearing
  # the bot's identity and be refused as a GitHub App (seen for real in a
  # copy's red run; kit 13 removes the header for the push and puts it back).
  # Capture and remove; Restore-KitCheckoutAuth re-adds them (the race-retry's
  # pull --rebase needs the ordinary bot auth again). Values are never printed.
  $script:kitHeaderBackup = @()
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $raw = @(& git config --local --get-regexp '^http\..*\.extraheader' 2>$null)
    foreach ($line in $raw) {
      $i = $line.IndexOf(' ')
      if ($i -gt 0) {
        $script:kitHeaderBackup += [pscustomobject]@{
          key   = $line.Substring(0, $i)
          value = $line.Substring($i + 1)
        }
      }
    }
    foreach ($e in $script:kitHeaderBackup) {
      & git config --local --unset-all $e.key 2>$null | Out-Null
    }
  }
  finally { $ErrorActionPreference = $prevEap }
  if ($script:kitHeaderBackup.Count) {
    Write-Host ("Removed {0} checkout credential header(s) for the token push (restored right after)." -f $script:kitHeaderBackup.Count)
  }
}

function Restore-KitCheckoutAuth {
  # Best-effort restore of the headers captured by Clear-KitCheckoutAuth.
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    foreach ($e in $script:kitHeaderBackup) {
      & git config --local $e.key $e.value 2>$null | Out-Null
    }
  }
  finally { $ErrorActionPreference = $prevEap }
  $script:kitHeaderBackup = @()
}

function Invoke-KitPush {
  # One push attempt. The output is captured into $script:lastPush for the
  # refusal classification and every line is echoed, exactly as an
  # uncaptured push would print it. The capture runs under 'Continue'
  # explicitly: on Windows PowerShell 5.1, native stderr under 'Stop'
  # becomes a terminating NativeCommandError (a trap this kit's own gh
  # probes hit before), and the push output is pure stderr. On the token
  # path the checkout's bot-token header is removed for the attempt and
  # restored afterwards (see Clear-KitCheckoutAuth).
  param([string]$Branch)
  $target = if ($kitPushUrl) { $kitPushUrl } else { 'origin' }
  if ($kitPushUrl) { Clear-KitCheckoutAuth }
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $exit = 1
  try {
    $script:lastPush = @(& git push $target "HEAD:$Branch" 2>&1 | ForEach-Object { "$_" })
    $exit = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $prevEap
    if ($kitPushUrl) { Restore-KitCheckoutAuth }
  }
  foreach ($line in $script:lastPush) { Write-Host $line }
  return $exit
}

function Test-PushWasWorkflowRefusal {
  # GitHub's rejection, seen for real in a copy's red run:
  #   ! [remote rejected] HEAD -> main (refusing to allow a GitHub App to
  #   create or update workflow '.github/workflows/...' without 'workflows'
  #   permission)
  $text = ($script:lastPush -join "`n")
  return (($text -cmatch 'refusing to allow .* to create or update workflow') -or ($text -imatch 'without .workflows. permission'))
}

$kitWorkflowRefusalHelp = @"
GitHub refused this push as a GitHub App (the repository's automatic bot
token): pushes that change files under .github/workflows need the
'workflows' permission, and GitHub does not allow that token to have it.
This kit cannot change the rule. The fix is a one-minute personal token:

  1. Create a fine-grained personal access token (GitHub, top-right avatar,
     Settings > Developer settings > Fine-grained tokens > Generate new
     token): repository access = ONLY this repository; repository
     permissions: Contents = Read and write, Workflows = Read and write;
     expiry = whatever you prefer (a fresh token replaces it when due).
  2. In THIS repository: Settings > Secrets and variables > Actions >
     Secrets > New repository secret. Name: KIT_PUSH_TOKEN. Value: the
     token.
  3. Run this workflow again. The push then lands, and every future kit
     sync stays one-click.

The 'Template update available' issue shows these steps too, plus the
terminal route that never needs a token (the token is only for this
button).
"@

$kitWorkflowRefusalTokenUsedHelp = @"
The push was refused as a GitHub App even though KIT_PUSH_TOKEN was in
use - it went out wearing the bot's identity. On kits before 13 the
checkout's stored bot-token header overrides the personal token in the
push URL (kit 13 removes that header for the push). The one-time way out
that ignores the button entirely: the terminal route in the 'Template
update available' issue (four git commands in any clone or codespace).
Once that sync lands, the button works with the token you already have.
If this copy is already at kit 13 or newer, check the token itself: it
must be a fine-grained personal access token with Contents = Read and
write and Workflows = Read and write on THIS repository.
"@

$pushExit = Invoke-KitPush -Branch $branch
if ($pushExit -ne 0) {
  if (Test-PushWasWorkflowRefusal) {
    # A permanent refusal - retrying can never help. Say so, loudly, once.
    $refusalHelp = if ($kitPushUrl) { $kitWorkflowRefusalTokenUsedHelp } else { $kitWorkflowRefusalHelp }
    throw $refusalHelp
  }
  if ($kitPushUrl -and (($script:lastPush -join "`n") -imatch 'authentication failed')) {
    throw "The KIT_PUSH_TOKEN credential was refused by GitHub (the push failed to authenticate): the token is expired or lacks Contents+Workflows write on this repository. Create a fresh fine-grained token and replace the KIT_PUSH_TOKEN secret, then run this workflow again."
  }
  Write-Host "Push raced another run (likely the state heartbeat); retrying once with pull --rebase - the same rescue the nudge issue gives to terminal users."
  git pull --rebase origin "$branch"
  if ($LASTEXITCODE -ne 0) { throw "Could not rebase onto $branch (a concurrent run may still be pushing); rerun this workflow in a minute" }
  $pushExit = Invoke-KitPush -Branch $branch
  if ($pushExit -ne 0) {
    if (Test-PushWasWorkflowRefusal) {
      $refusalHelp = if ($kitPushUrl) { $kitWorkflowRefusalTokenUsedHelp } else { $kitWorkflowRefusalHelp }
      throw $refusalHelp
    }
    throw "Push to $branch failed after the retry; rerun this workflow in a minute"
  }
}

Write-Host "Synced to the template: kit version $templateVersion."
Add-SummaryLine "Kit sync: **$localVersion -> $templateVersion** - committed and pushed. The next build run will use the new kit files."

# ---- close the open update issues (best effort, never fails the sync) --------
Close-NudgeIssues -Note "The sync was taken from the template (kit version $templateVersion is now in this repository), so every open update-notice here is closed. The next build run will already use the new kit files."

exit 0
