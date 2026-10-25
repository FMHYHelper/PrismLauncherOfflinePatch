# notify-kit-update.ps1
#
# Runs at the start of every workflow run in a repository created from the
# template (parallel with the build, never gating or delaying anything).
# Compares this copy's KIT-VERSION (a single-line number) against the template
# the copy came from, and keeps the "Template update available" issue in step:
#
#   copy behind the template  -> newest open notice gets a dated status
#                                comment; any older duplicate notices are
#                                closed as superseded (and one is created if
#                                none exists)
#   copy in step              -> ALL open notices are closed (they are stale
#                                the moment versions match)
#
# Fail-soft by contract: nothing here may turn a run red. Every failure is
# printed as a ::warning:: plus a step-summary line, and the script exits 0.
# Opt-out is handled in the workflow (repo variable kit_updates_off / KIT_UPDATES_OFF).

$ErrorActionPreference = 'Stop'

$template   = if ($env:TEMPLATE_SOURCE) { $env:TEMPLATE_SOURCE } else { 'FMHYHelper/PrismLauncherOfflinePatch' }
$issueTitle = 'Template update available'
$summaryFile = $env:GITHUB_STEP_SUMMARY

function Add-SummaryLine {
  param([string]$Text)
  if ($summaryFile) {
    try { Add-Content -Path $summaryFile -Value $Text } catch { }
  }
}

function Get-OpenNudgeIssues {
  # Every open issue titled exactly like the update notice (normally one;
  # more than one is possible and they are handled, not ignored).
  $issues = @()
  $raw = gh issue list --state open --json number,title 2>$null
  if ($LASTEXITCODE -ne 0) { throw "gh issue list failed (exit $LASTEXITCODE)" }
  if (-not [string]::IsNullOrWhiteSpace("$raw")) {
    $issues = @(ConvertFrom-Json ([string]$raw) | Where-Object { $_.title -ceq $issueTitle })
  }
  return @($issues)
}

try {
  # ---- Versions -----------------------------------------------------------

  $remoteVersion = ([string](Invoke-RestMethod "https://raw.githubusercontent.com/$template/main/KIT-VERSION")).Trim()

  $localVersion = 'not recorded'
  if (Test-Path 'KIT-VERSION') {
    $localVersion = ([string](Get-Content 'KIT-VERSION' -Raw)).Trim()
  }

  $inStep = ($localVersion -eq $remoteVersion)

  Write-Host ("KIT-VERSION check: template '{0}' / this copy '{1}'" -f $remoteVersion, $localVersion)

  # ---- One open "Template update available" issue, if any ------------------

  $existing = Get-OpenNudgeIssues
  # newest first (issue list returns created descending)
  $match = $null
  if ($existing.Count -gt 0) { $match = $existing[0] }

  # ---- Act ----------------------------------------------------------------

  if (-not $inStep) {
    $day = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')

    # Older duplicate notices are stale versions of the same message; keep
    # exactly one alive and retire the rest.
    foreach ($extra in @($existing | Select-Object -Skip 1)) {
      gh issue close $extra.number --reason completed --comment "Superseded by #$($match.number), which carries the current steps (template is now at $remoteVersion)."
      if ($LASTEXITCODE -eq 0) {
        Write-Host "Older duplicate notice #$($extra.number) closed in favor of #$($match.number)."
      } else {
        Write-Host "::warning::Could not close duplicate notice #$($extra.number)."
      }
    }

    if ($match) {
      $note = "Still out of date (checked UTC $day): template **$remoteVersion**, this copy **$localVersion**. The quickest sync is the one-click route in this issue's toolkit (it needs the one-time KIT_PUSH_TOKEN token setup described there): Actions tab -> Sync kit files from template -> Run workflow."
      gh issue comment $match.number --body $note
      if ($LASTEXITCODE -ne 0) { throw "gh issue comment failed (exit $LASTEXITCODE)" }
      Write-Host "Out of date; posted a status comment on issue #$($match.number)."
      Add-SummaryLine "Kit update check: **out of date** - template **$remoteVersion**, this copy **$localVersion** (updated issue #$($match.number))."
    }
    else {
      $bodyTemplate = @'
This copy of the offline-patch kit is **{LOCAL_VERSION}** while the template is now at **{REMOTE_VERSION}**. The template picked up changes (new or updated `patches/`, workflow, scripts, docs) that this copy does not have yet.

Nothing has stopped working: this copy keeps building with the files it already has. But new upstream support, fixes and doc improvements only arrive after you take the template's updates.

## Taking the update

### One-click way (needs a one-time personal token)

GitHub, by its own security rule, refuses pushes that change workflow
files when they come from the repository's automatic bot token - and
every kit sync carries workflow files. GitHub does not even let that
token be granted the "workflows" permission, and this kit cannot switch
the rule off. So the button runs on a personal token added once, and
every future sync stays one-click from then on:

1. Make a **fine-grained personal access token**: GitHub, top-right
   avatar -> Settings -> Developer settings -> Fine-grained tokens ->
   Generate new token. Scope it to **only this repository**, and give
   the repository permissions **Contents: Read and write** plus
   **Workflows: Read and write**. Expiry as you like - replacing an
   expired token and updating the secret below is the whole maintenance
   story.
2. Store it in this repository as a **secret named `KIT_PUSH_TOKEN`**:
   Settings -> Secrets and variables -> Actions -> Secrets -> New
   repository secret (name: `KIT_PUSH_TOKEN`, value: the token). GitHub
   only releases a secret to workflows at run time - nobody can read it
   back afterwards, and this kit does not try.
3. Take the update: **Actions** tab -> **"Sync kit files from
   template"** -> **"Run workflow"**, twice to confirm. The sync pushes
   with your token, closes this issue on the spot, and later template
   updates stay that one same click. (A red run for any *other* reason -
   a network hiccup, a raced heartbeat - just means run it again a
   minute later.)

If this copy is still on **kit 9 or older**: its own button predates the
token logic, so the *very next* sync (to kit 10) must take the
**terminal way** below. After that one-time hop, the button with the
token applies forever. And a button run that turns red saying
"refusing to allow a GitHub App to create or update workflow" means the
secret is missing: step 1 above is the fix.

(To also get the new version's launcher compiled right away, afterwards click **"Build patched Prism Launcher"** -> **"Run workflow"** once. Otherwise the next scheduled run does it anyway.)

### Terminal way

From any clone of this repository:

```
git remote add template https://github.com/{TEMPLATE_URL}.git
git fetch template

git checkout template/main -- .github/workflows README.md MAINTAINING.md KIT-VERSION docs patches scripts

git commit -m 'Sync kit files from template (kit version {REMOTE_VERSION})'
git push
```

(If a remote named `template` already exists, swap the `add` line for
`git remote set-url template https://github.com/{TEMPLATE_URL}.git`.)

If the push is rejected with "remote contains work that you do not have" or
a hint about fetching first: this repository's automatic bookkeeping commits
have moved ahead of your clone. Run

```
git pull --rebase origin main
```

and push again - your one sync commit lands on top of them harmlessly.
Never force push.

Either route replaces the whole kit - workflow, patch files, scripts, docs
and the version marker - with the template's copies, leaving everything
else in the repository (including the `.state/` bookkeeping) untouched.
After the push, the next run uses the new files, and this issue closes
itself. (The one-click route closes it before the run, too.)

## Preferring silence

Set the repository **variable** (not a secret) `KIT_UPDATES_OFF` to `true`
(Settings -> Secrets and variables -> Actions -> Variables) and this check
stops running entirely from the next run on. Closing this issue without
syncing does not prevent a fresh one from being filed on a later run; the
variable is the real opt-out.
'@
      $body = $bodyTemplate.Replace('{REMOTE_VERSION}', $remoteVersion).Replace('{LOCAL_VERSION}', $localVersion).Replace('{TEMPLATE_URL}', $template)
      $body | gh issue create --title $issueTitle --body-file -
      if ($LASTEXITCODE -ne 0) { throw "gh issue create failed (exit $LASTEXITCODE)" }
      Write-Host "Out of date; filed issue 'Template update available'."
      Add-SummaryLine "Kit update check: **out of date** - template **$remoteVersion**, this copy **$localVersion** (filed the update issue)."
    }
  }
  else {
    $day = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    foreach ($open in $existing) {
      $note = "Kit version back in step: template **$remoteVersion**, this copy **$localVersion**. Every open update-notice here was stale, so it is closed as completed."
      gh issue close $open.number --reason completed --comment $note
      if ($LASTEXITCODE -ne 0) {
        Write-Host "::warning::gh issue close failed for #$($open.number) (exit $LASTEXITCODE)"
      }
      else {
        Write-Host "In step; closed issue #$($open.number)."
      }
    }
    if ($existing.Count -gt 0) {
      Add-SummaryLine "Kit update check: versions match (**$remoteVersion**) - closed $($existing.Count) open notice(s)."
    }
    else {
      Add-SummaryLine "Kit update check: versions match (**$remoteVersion**)."
    }
  }

  exit 0
}
catch {
  $msg = ($_.Exception.Message -replace "`r?`n", ' ')
  Write-Host "::warning::Kit-update nudge failed soft (run stays green): $msg"
  Add-SummaryLine 'Kit update check: **failed soft** - see the warning in this job''s log. The run itself is unaffected.'
  exit 0
}
