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

## Multi-platform builds (kit 6)

Since kit 6 a run builds every platform the official release leads with, in
parallel, and pools them into one release per tag:

- **Windows-MSVC** (`windows-2022`): the bare `PrismLauncher.exe` plus
  `PrismLauncher-Windows-MSVC-Portable-<tag>.zip` from the tag's own
  packaging action. The NSIS installer is built as a side effect of that
  action but intentionally not attached: an unsigned installer adds
  SmartScreen friction for nothing, the portable zip covers the same need.
- **Linux x86_64** (`ubuntu-24.04`): AppImage + portable tarball from the
  tag's own packaging action. GPG signing inputs stay unset, so the
  AppImage is unsigned (the action warns and continues). Its zsync update
  field points at the copy's own releases; it is harmless and unused here,
  since the in-app updater is official-build territory.
- **macOS universal** (`macos-26`, deployment 12.0, Qt 6.9.3): DMG, ad-hoc
  signed (`AdhocSignedApp.entitlements`), notarization skipped without
  credentials. This is the only channel macOS has on the kit - the Sparkle
  self-updater path stays unused, so macOS updates are manual replacements.

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

## Why the template itself publishes nothing (kit 6 shape)

The `publish` job is gated on `vars.no_binaries != 'true'`, same as the old
in-build publish step was. On this template the build matrix still runs - it
proves the patches keep applying to real upstream tags - and then nothing is
published; the finalize job treats a skipped publish as normal there.
