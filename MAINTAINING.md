# Maintaining this template

Repositories created from this template are meant to be edited freely - via the
web UI or however you like. This file is for whoever maintains the *original*
template branch itself.

Most days this repo runs itself and you touch nothing. The daily run either
verifies the patch against the newest upstream release and updates one
bookkeeping line (`.state/last-build.json`) - this repository publishes
**nothing** - or, in an already-handled state, just keeps the heartbeat alive.
That bookkeeping commit is expected - remove the `schedule:` block
in the workflow file if you ever want the repo to stay completely silent instead.

## Why the template itself publishes nothing

The template is deliberately binary-free: it is a patch-delivery tool, and the
patched exe is produced by whoever uses it, in their own repository. Two
mechanisms in the workflow enforce that:

- The `Publish release` step is gated on `vars.no_binaries != 'true'`. Set the
  repository **variable** `no_binaries` (not a secret) to `true` on any
  repository that must never host builds - currently only this template.
  Repositories created with **Use this template** start without the variable
  and therefore publish releases there, exactly as their user expects.
- The decision script receives the same flag via `PRISM_PUBLISH` and switches
  to state-driven behavior (catch-up). In publishing repositories it applies
  the stricter rule that a tag only counts as handled if a release for it
  exists in that repository - this covers copies that inherit the template's
  `.state/last-build.json` with no release history of their own.

## Editing the template

1. Before authoring any change, absorb the bookkeeping commits first:

   ```
   git fetch public && git merge --ff-only public/main
   ```

2. Make your edits on your own working copy, commit them, then push to your
   public mirror. Web-editor commits on the public mirror will appear under
   whichever account was logged in - avoid that if you want a neutral history.

3. Never force-push the public branch; people create their own projects from it.

## Patch inventory

Every behavioral difference between the built exe and upstream lives in a
public file under `patches/`. The rules:

- One numbered patch file per coherent change (`NNN-short-name.patch`), plain
  unified diff against an exact upstream tag, written to apply after the
  lower-numbered files (the build applies them in sorted name order).
- Every patch is described in two places, kept in step with the code: the
  README section *What the patch changes*, and the release notes produced
  from `docs/release-notes-template.md`. A release shipping a patch that is
  not described in both is a bug.
- No behavior change outside `patches/`: no hidden fork, no source edits in
  the workflow's build step. The release's `source-patches-<tag>.patch`
  bundle is the complete inventory of what the exe differs by.
- Adding one: draft against a throwaway clone of the exact upstream tag,
  apply-test in CI order (`git apply --check` then `git apply`, ascending),
  update README + release-notes template + this list in the same commit,
  then push with the usual fetch/ff-only discipline.
- Any change a downstream copy should receive - a new or edited patch file,
  workflow, script, doc or README fix - also bumps the single-line number in
  `KIT-VERSION` by 1, **in the same commit**. That number is the only signal
  the template-update check in every copy compares (see the README section
  *Keeping your copy in step with the template*), so a kit change without its
  bump is a bug: every copy stays silently out of date.

## Commit identity

This repo intentionally carries no maintainer identity in its history. Use any
neutral commit identity you like locally; nothing here should link to a person.
The automation commits as the standard GitHub Actions identity.

## Provenance

`docs/fingerprint.txt` holds two values that the producer of each bundle uses to
verify their own builds. Both are opaque by design: one is a hash with no public
preimage, the other a public verification key. They are not decoded here and
should not be.

## Multi-platform builds (kit 6, release shape reshaped in kit 9)

Since kit 6 a run builds every platform the official release leads with, in
parallel, and pools them into one release per tag:

- **Windows-MSVC** (`windows-2022`): the bare `PrismLauncher.exe`, a
  drop-in for the official `prismlauncher.exe`, and nothing else. Since
  kit 11 the job skips the tag's Windows packaging action entirely: its
  NSIS installer, portable zip and binary zip were never claimed by the
  kit, and its pinned NSCurl download (a fixed GitHub release fetched on
  every run) was a pure external flake point - it killed a real copy run
  on 2026-10-25 with the compile itself already green. The shipped exe
  is the build tree's own `prismlauncher.exe` - the same recursive
  search every kit-6+ run has used - so nothing the kit claims changes.
  The zip's old job (fresh starts, offline version-jump fallback)
  remains covered by the documented official-first update order: the
  official update owns and rights the Qt runtime files, and the exe
  paste follows it.
- **Linux x86_64** (`ubuntu-24.04`): the AppImage, nothing else - one
  self-contained file that replaces the official AppImage; the platform
  has no version-jump dance because the file carries its own Qt
  runtime. The portable tarball is still built as a side effect and is
  not attached since kit 9. GPG signing inputs stay unset, so the
  AppImage is unsigned (the action warns and continues). Its zsync update
  field points at the copy's own releases; it is harmless and unused here,
  since the in-app updater is official-build territory.
- **macOS universal** (`macos-26`, deployment 12.0, Qt 6.9.3): the DMG,
  the easy whole-app route, plus the bare universal binary
  `prismlauncher-macos` staged out of the freshly packaged bundle for
  the drop-in swap route - documented with its one-line arm64 re-sign in
  the README's macOS tutorial. Upstream's action also writes a binary
  zip as a side effect, not attached. The bundle and binary are ad-hoc
  signed (`AdhocSignedApp.entitlements`) and notarization is skipped
  without credentials, and the Sparkle self-updater path stays unused -
  macOS updates are manual replacements on either route.

### How the recipes are read

`scripts/common.ps1` reads each platform's matrix entry out of the tag's own
`build.yml` (`Get-UpstreamPlatformRecipe`) and validates presets against the
tag's `CMakePresets.json`. Strictness when a recipe cannot be read:

- Windows recipe on a **stable** tag or a **manual** `upstream_ref`: fatal.
  No build, no release, no state advance - the run shows red and retries.
- Windows recipe on a **pre-release**: that pre-release is skipped, so it
  can never block the stable build.
- Linux/macOS recipes anywhere: the platform is skipped with a warning and
  everything else still builds. Upstream restructuring its Linux or macOS
  CI must never cost a copy its Windows exe.

### The `platforms` repository variable

`Settings > Secrets and variables > Actions > Variables > platforms`:
comma or space separated subset of `windows`, `linux`, `macos`; empty or
`all` means all three. A typo degrades gracefully (unknown names are warned
about and ignored; an entirely invalid value builds all platforms instead
of silently building nothing).

Cost picture (standard runners): on a **public** repository all three
platforms are free. On private repositories minutes multiply: Linux 1x,
Windows 2x, macOS 10x - hence the variable.

Two interactions worth knowing:

- `force_rebuild` deletes and recreates a release, so the rebuilt release
  contains only what this run produced. A rebuild while `platforms` excludes
  a platform makes that platform's files vanish until the next unfiltered
  build of the same tag - rebuild unfiltered to restore the full set.
- The publish step no longer lives inside the build jobs: build jobs only
  upload `release-<tag>-<platform>` artifacts, and one `publish` job merges
  them per tag (patch bundle, one checksums.txt, release notes) and creates
  or refreshes the release. A single failed platform turns the run red and
  no tag is advanced in state - the next run rebuilds the whole trio.

## The sync-from-template button (kit 7)

Since kit 7 each copy has a second, manual-only workflow:
**Sync kit files from template** (`workflow_dispatch`). It takes the
template update for the user - the one-click route documented in the nudge
issue - by doing exactly what the issue's terminal commands do: point a
`template` remote at the kit's source, fetch, overlay the kit paths
(`.github/workflows README.md MAINTAINING.md KIT-VERSION docs patches
scripts`), commit as `github-actions[bot]` and push.

Behavioral rules, all in `scripts/sync-kit.ps1`:

- **Manual only.** Plain `workflow_dispatch`, no schedule. Updating a copy
  must stay an explicit act; the nudge keeps carrying the guidance, the
  button just makes acting on it beginner-friendly.
- **Fail loud, unlike the nudge.** A user pressed a button: anything that
  cannot complete is a red run with an explanatory message, not a silent
  warning. Push refusals are sorted into two opposite classes (kit 10):
  a push raced by a build run's state heartbeat - one automatic
  `git pull --rebase` + push retry first (the same rescue the issue text
  teaches); and GitHub's workflow-file rule - a *permanent* refusal (the
  remote rejects any workflow-file push from GITHUB_TOKEN, and the kit's
  overlay always carries workflow files), which is never retried and
  fails with the exact KIT_PUSH_TOKEN setup steps. A refused
  KIT_PUSH_TOKEN (expired or under-scoped token) is reported on its own,
  without the heartbeat retry in between.
- **Idempotent.** Equal or newer versions push nothing and close any
  stale notices; older versions sync and then close EVERY open
  "Template update available" issue (they are all stale the moment the
  push lands; normally there is exactly one, but hand-closed-then-refiled
  churn can leave strays).
- **Overlay semantics identical to the issue commands**: files still in
  the template are refreshed; anything else in the copy is untouched,
  including extra files a user has added inside `patches/` or `docs/`.
  (Known pre-existing wrinkle, shared with the terminal route: files that
  upstream later *removed* from the kit linger until removed by hand -
  the kit avoids removals for exactly this reason.)
- **Cost**: one runner-minute, on demand. The button does not build
  anything; the next build run uses the new kit files.
- The workflow is ASCII-clean, hardcoded to `TEMPLATE_SOURCE:
  FMHYHelper/PrismLauncherOfflinePatch`, and refuses to sync the template
  repository with itself.

### The workflow-file push rule and KIT_PUSH_TOKEN (kit 10)

The kit-9 rollout met the rule for real: a copy's button run synced kit 9
and GitHub refused the push with *"refusing to allow a GitHub App to
create or update workflow ... without workflows permission"*. GITHUB_TOKEN
cannot carry that permission at all - it is absent from the token's scope
table entirely, so no `permissions:` declaration can help - while the
kit's overlay always includes `.github/workflows`. Kit 10 therefore does
what the GitHub docs prescribe for exactly this case: a fine-grained
personal access token (Contents + Workflows read/write, the copy's
repository only) stored as the **secret** `KIT_PUSH_TOKEN`. When the
secret exists, sync-kit.ps1 pushes through a one-shot token-in-URL push
(`https://x-access-token:...@github.com/...` - never written into any
config, never printed, and the runner masks the value regardless); when
it does not exist, the refusal is detected, never race-retried, and the
run fails loud with the setup steps.

- The token path activates only for github.com https remotes; local
  file-path origins (the dry-run rig) keep the plain push, so the rig
  stays representative and nothing network-bound runs there. Rig
  scenarios under a rejecting pre-receive hook prove the
  classification: workflow-file diffs turn red with the setup text after
  exactly one push attempt; non-workflow diffs push green.
- Copies at kit 9 or older run their own button logic and cannot use the
  token at all - their first hop to kit 10 is the terminal route (user
  credentials carry full rights), one time, then the button and the
  token take over. Copies created fresh from the template start at kit
  10 with the logic already in their hands, and their nudge issue leads
  them through the one-time token setup.

### The stale-kit build gate (kit 12)

A copy behind the template no longer builds at all. `decide.ps1` compares
the copy's `KIT-VERSION` against the template's (one unauthenticated
`raw.githubusercontent.com` fetch) and, when the copy is behind, emits
`has_builds=false` - so the build matrix and publish skip through the
existing gates, `finalize` still runs and advances nothing, and the run
stays green. The rule came from a real run: a stale copy's manual rebuild
burned a 30-minute Windows job dying in a flake zone kit 11 had already
removed. Building from an old kit is never worth runner time.

- The skip is loud by design: a `BUILDS SKIPPED` banner in the decide
  log, a `::warning::` annotation, a run-summary line, and the nudge
  issue (which also says builds are paused while behind). The run page
  answers "why did nothing build" without opening any log.
- Fail-open by contract: only a positive, parsed comparison (both
  versions integers, local < remote) skips the run. Network trouble,
  a missing file or an unparseable version builds as before, with a
  warning line. `KIT_UPDATES_OFF` silences the notice but not the gate.
- Bypasses: the template itself never gates (`GITHUB_REPOSITORY` equal
  to `TEMPLATE_SOURCE` - it defines "current"); local batteries with
  `KIT_TEST_RELEASES_FILE` bypass it; the gate itself is testable offline
  via `KIT_TEST_TEMPLATE_KIT_VERSION`; and the repository variable
  `build_if_old` = `true` is the documented emergency hatch (e.g. while
  a broken kit sits at the template's tip and a copy needs builds now).
- Gating lives in `decide` (one runner-minute job) rather than as a
  `needs:` edge on the build job, so no job-skip cascade semantics are
  involved: everything downstream rides the existing has_builds=false
  path that "nothing new upstream" runs have always taken.

## Why the template itself publishes nothing (kit 6 shape)

The `publish` job is gated on `vars.no_binaries != 'true'`, same as the old
in-build publish step was. On this template the build matrix still runs - it
proves the patches keep applying to real upstream tags - and then nothing is
published; the finalize job treats a skipped publish as normal there.
