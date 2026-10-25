# notify-kit-update.ps1
#
# Runs at the end of every build in a repository created from the template.
# Compares this copy's KIT-VERSION (a single-line number) against the template
# the copy came from, and keeps exactly one issue ("Template update available")
# in step with reality:
#
#   copy behind the template  -> creates the issue, or posts a dated status
#                                comment on the one that is already open
#   copy in step              -> closes the issue if one is open (resolved)
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

  $raw = gh issue list --state open --json number,title
  if ($LASTEXITCODE -ne 0) { throw "gh issue list failed (exit $LASTEXITCODE)" }

  $existing = @()
  if (-not [string]::IsNullOrWhiteSpace("$raw")) {
    $existing = @($raw | ConvertFrom-Json | Where-Object { $_.title -ceq $issueTitle })
  }
  $match = $null
  if ($existing.Count -gt 0) { $match = $existing[0] }

  # ---- Act ----------------------------------------------------------------

  if (-not $inStep) {
    $day = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')

    if ($match) {
      $note = "Still out of date (checked UTC $day): template **$remoteVersion**, this copy **$localVersion**."
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

That replaces the whole kit - workflow, patch files, scripts, docs and the
version marker - with the template's copies, leaving everything else in the
repository (including the `.state/` bookkeeping) untouched. After the push,
the next run uses the new files, and this issue closes itself.

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
    if ($match) {
      $note = "Kit version back in step: template **$remoteVersion**, this copy **$localVersion**. The sync provided in this issue was taken, so closing as completed."
      gh issue close $match.number --reason completed --comment $note
      if ($LASTEXITCODE -ne 0) { throw "gh issue close failed (exit $LASTEXITCODE)" }
      Write-Host "In step; closed issue #$($match.number)."
      Add-SummaryLine "Kit update check: versions match (**$remoteVersion**) - closed issue #$($match.number)."
    }
    else {
      Write-Host "In step; nothing to do."
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
