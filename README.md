# Prism Launcher Offline-Patch Template

A tiny repository that runs one job on autopilot: it checks
[Prism Launcher](https://github.com/PrismLauncher/PrismLauncher) upstream
releases daily and keeps a small, fully disclosed patch set in step with them
- it removes the client-side checks that gate offline accounts (creating one,
and launching with one selected) and gives offline-only setups the pieces of
an online session they cannot reach otherwise: the account picker in place of
the login nag when nothing is selected, and the one public download pass at
launch time when files are missing. Nothing else about the launcher is
modified.

**This repository hosts no binaries.** It is the tool, not the distribution:
no launcher code is stored here. Every build starts from a fresh clone of an
upstream release tag, your patch files from `patches/` are applied on top of
it, and the patched builds - the Windows exe (drop-in for the official one),
the Linux AppImage, and the macOS pair (DMG plus bare binary) - plus the
exact source patch land in *your own copy's* Releases tab when you run it
there. That makes the whole thing easy to read and easy to extend: a patch
is one plain-text file.

---

## Why this template exists

Instead of downloading a launcher that somebody patched behind the scenes,
you take Prism Launcher's official source, apply a small set of patches you
can read in full here, and build it yourself in your own repository. Every
claim this project makes about what was changed can be checked against the
actual files in `patches/`, and every release you publish ships the exact
diff that was applied to the upstream code. A pre-built fork asks you to
trust its author; this asks you to read a few dozen lines.

The reason the patches exist: Prism Launcher refuses to let purely offline
accounts work unless a Microsoft account that owns the game is also in the
list. That is a client-side convention, not a technical necessity. If your
machine is offline at play time, if the computer is shared, or if you simply
prefer not to sign in with a Microsoft account for offline play, that gate
stands in the way for no benefit. The patches here remove those client-side
checks and add the small offline conveniences described below.

To be plain about what does not change: the launcher still talks to the
game's own public servers for the things it genuinely downloads (version
metadata, libraries, assets), Microsoft accounts keep every one of their
stock behaviors, and online-mode servers keep verifying accounts
server-side. Nothing here bypasses a server check; it only stops the
launcher from demanding a Microsoft login when you never asked for one.

---

## The easy way (5 steps, about 40 minutes once)

**Step 1.** On this page, click the green **"Use this template"** button (top
right), then **"Create a new repository"**. Name it anything you like and click
**Create repository**.

**Step 2.** In your new repository open **Settings > Actions > General**. At the
bottom, under **Workflow permissions**, choose **Read and write permissions** and
click **Save**.

**Step 3.** Click the **Actions** tab. If a banner asks you to confirm, click the
button to enable workflows.

**Step 4.** Still in Actions, click **"Build patched Prism Launcher"** on the
left, then **"Run workflow" > "Run workflow"**. Wait about 40 minutes - it is
compiling the launcher from real source code.

**Step 5.** Open the **Releases** page **of your own new repository**. Download
**`PrismLauncher.exe`** (the only `.exe` there), open your existing Prism
Launcher folder (the official installer's default location is
`%LocalAppData%\Programs\PrismLauncher` - not `%AppData%\PrismLauncher`,
which holds your accounts and instances, not the exe; for a portable copy
it is wherever you unzipped it), keep a copy of the original exe, and paste the
download in, replacing the old `prismlauncher.exe` - keeping that exact
name, which the folder's shortcuts and the updater's backup logic point
to. Taking it on macOS, Linux or a Steam Deck? Skip down to *Installing
on each platform*.

After that you do nothing. When the launcher team publishes a new version, a
fresh patched build shows up in your Releases within a day - for every
platform your copy builds.

> Rather not do the paste by hand every time? Releases also carry a small
> **update helper** - plain scripts that do the same swap for you, checksum
> check and backup included. It is optional, you run it yourself, and it is
> never built into the launcher. See *Updating with the helper* below.

## What gets built, and where

Every upstream version produces one release in your copy containing, for the
flagship flavour of each platform (the same one the official release leads
with):

| File | For | How to use it |
|---|---|---|
| `PrismLauncher.exe` | Windows | drop-in for the official `prismlauncher.exe` (tutorial below: Windows) |
| `PrismLauncher-Linux-x86_64.AppImage` | Linux, Steam Deck | one self-contained file, named exactly like the official one - replaces it in place (tutorial below: Linux) |
| `PrismLauncher-macOS-<tag>.dmg` | macOS | a complete app, drag to Applications (tutorial below: macOS route 1) |
| `prismlauncher-macos` | macOS | the bare patched binary, swapped into an official app (tutorial below: macOS route 2) |
| `source-patches-<tag>.patch` + `checksums.txt` | all | the exact source diff applied, and the expected checksums of every file |
| `update-patcher.ps1` / `.sh` + the `update-*.cmd` wrappers | all | the optional update helper - plain scripts you download and run yourself (see *Updating with the helper*) |

Notes worth having in writing:

- **Nothing is signed.** This kit holds no vendor signing credentials, so the
  Windows builds are unsigned (SmartScreen may warn: *More info* then *Run
  anyway*, after checking the checksum), the macOS builds are ad-hoc signed
  (Gatekeeper asks on first launch, and the binary-swap route needs one
  re-sign line on Apple Silicon - both covered in the macOS tutorial), and
  the Linux builds are unsigned. `checksums.txt` is the integrity check
  to use instead.
- **Steam Deck**: desktop mode only - the Linux tutorial below carries the
  steps. This is not the Flathub build: upstream's official Flathub channel
  continues to exist on its own and is untouched by this template.
- **The in-app updater only knows official builds** (that is exactly what
  the version-jump section below relies on). Updating a *patched* install
  means replacing its files from your own Releases - by hand as in the
  tutorials, or with the optional helper described below.
- **Need fewer platforms?** macOS runners cost about 10x the minutes on
  private repositories (Windows 2x, Linux 1x; all three are free on public
  repositories). Set the repository **variable** `platforms` (same place as
  `no_binaries`) to any of `windows`, `linux`, `macos` - comma or space
  separated, or leave it unset for all three.

### Installing on each platform

All routes below are plain file moves - no installer of this template's
exists at any point. The order is the same everywhere: have the official
release of the same version present first, then put the patched file on
top of it. And check every download against `checksums.txt` once.

**Windows - the exe paste:**

1. Have the official **Windows-MSVC** build of the same version installed
   (official installer or official portable zip - either), and quit the
   launcher if it is running.
2. Download `PrismLauncher.exe` from your copy's Releases.
3. Open your existing Prism Launcher folder - the official installer's
   default location is `%LocalAppData%\Programs\PrismLauncher`; for a
   portable copy it is wherever you unzipped it. Do not confuse this with
   `%AppData%\PrismLauncher` - that folder holds your accounts and
   instances, not the exe. Keep
   a copy of the original `prismlauncher.exe` (rename it to
   `prismlauncher.exe.orig`), then place the downloaded file there named
   exactly `prismlauncher.exe` - that name is what the folder's shortcuts
   and the updater's backup logic point to.
4. Run it. SmartScreen may warn once about the unsigned exe: choose
   *More info*, then *Run anyway*.

That is the whole procedure, and within one version line every new release
repeats it identically.

**Linux and Steam Deck - the AppImage swap:**

1. Have the official AppImage of the same version set up where you like
   it (upstream's release page, `chmod +x`, first run), and quit the
   launcher if it is running. Instances and settings live under
   `~/.local/share/PrismLauncher` and nothing in this swap touches them.
2. Download `PrismLauncher-Linux-x86_64.AppImage` from your copy's
   Releases. It is named exactly like the official one, so nothing needs
   renaming on your side.
3. Keep a copy of the original - rename the official file to
   `PrismLauncher-Linux-x86_64.AppImage.bak` (or move it elsewhere) -
   then put the patched file where the official one was. Keeping the
   official name is what keeps your menu entry or Steam shortcut working
   with no extra steps. If the browser stripped the executable bit, set
   it again: `chmod +x <the file you placed>`.
4. Run it. This swap is the entire update procedure on Linux: the
   AppImage carries its own Qt runtime, so a version jump is the same
   one-file swap with no extra steps - there is no Qt dance on Linux at
   all.

Steam Deck: switch to **desktop mode**, do exactly the above (a folder
like `~/Applications` works well), and press *Add to Steam* from the
file manager if you want it in your library. Never in gaming mode.

**macOS - two routes:**

Route 1 - the DMG, no terminal at all, updates like the official app:

1. Quit any running launcher. Download `PrismLauncher-macOS-<tag>.dmg`
   from your copy's Releases.
2. Open the DMG and drag `Prism Launcher` onto Applications, replacing
   the official copy (rename the old app to `Prism Launcher.orig` first
   if you want a rollback copy). This app *is* your install now: new
   versions arrive as a new DMG, drag over again.
3. First launch: Gatekeeper asks about the unsigned developer.
   Right-click the app and choose *Open*. On Apple Silicon, if macOS
   gives a harder refusal instead, open *System Settings > Privacy &
   Security* - the blocked app is listed there with an *Open Anyway*
   button.

Route 2 - the bare binary swap, into an official install (Apple Silicon:
this route needs exactly one terminal line, shown in step 3):

1. Quit any running launcher, and make sure the official app in
   /Applications is already the same version as the file (official
   first - the same order as Windows). Download `prismlauncher-macos`
   from your copy's Releases.
2. In Finder: `Applications > Prism Launcher`, right-click > *Show
   Package Contents* > `Contents` > `MacOS`. Keep a copy of the official
   `prismlauncher` binary (rename it `prismlauncher.orig`), then place
   the downloaded file there named exactly `prismlauncher`. Finder may
   ask for your password before replacing - that is the system guarding
   /Applications, say yes.
3. Launch once from Applications. On Apple Silicon, macOS will refuse
   ("damaged" or "cannot verify"): the bundle's signature no longer
   matches what is inside it - expected, not corruption. Re-sign the
   bundle once in Terminal:

   ```
   codesign --force --deep -s - "/Applications/Prism Launcher.app"
   ```

4. Launch again - the official install now runs the patched launcher,
   universal (Apple Silicon and Intel alike).

Both macOS routes keep everything else stock: accounts, instances and
settings stay exactly where the official launcher keeps them, and the
DMG is the same patched app packaged the official way.

## Updating with the helper (optional)

Every release also carries a handful of plain-text scripts named `update-*`
- the **update helper**. It is not part of the launcher and is never built
into it: the patched launcher contains exactly the four patches, nothing
else. The helper is a stand-in for your own hands - it downloads the newest
release from *this* repository (the copy's repository name is baked into the
script when that release is published), checks the file against
`checksums.txt`, backs the old file up, and swaps the new one in. It talks
to exactly two things: that repository's GitHub API and its download
servers. The scripts are plain text - read them before running them; that is
the point of everything here.

**Windows:** download `update-patcher.ps1` and the three `.cmd` wrappers
into any folder and double-click `update-prism.cmd`. The first run asks
where your Prism Launcher folder is; every later run compares versions and
only acts when a newer patched build exists. It also knows the one Windows
trap from the section above - a version jump needs the official update
first (the folder's Qt runtime files move with it) - so on a jump it says
so, waits, and re-applies the patch on its own once the official update has
run. The wrappers:

- `update-prism.cmd` - update now, interactively. When a new build is out,
  it asks with three choices: **Update**, **Cancel** (nothing happens until
  the next check), or **Ignore this update** (that exact version stops being
  suggested; the next release asks again. `update-patcher.ps1 apply -Yes`
  installs an ignored version anyway, without questions).
- `update-check-enable.cmd` - optional: a daily background check (a per-user
  scheduled task; no admin rights). It updates silently when the launcher is
  closed and only notifies you when a swap has to wait for you.
- `update-check-disable.cmd` - remove the background task again.
- `update-patcher.ps1` - the engine; run from a terminal it also has
  `check` (report only) and `status` modes.

**Linux and Steam Deck (desktop mode):** download `update-patcher.sh` and
run `bash update-patcher.sh`. Same deal - checksum, backup, swap in place -
and the file name never changes, so menu entries and Steam shortcuts keep
working. The swap is safe even while the launcher is running; the new
version starts at the next launch. `enable-check` / `disable-check` turn a
daily systemd user timer on and off. The update question is the same three
choices (Update / Cancel / Ignore this update), as a small dialog where a
desktop is present and in the terminal otherwise.

**macOS:** the same script - `bash update-patcher.sh` - mounts the new DMG,
verifies it, and swaps the app. The DMG was fetched by the script itself,
which leaves no quarantine mark, so Gatekeeper should not ask again. The
update question is the same three choices (Update / Cancel / Ignore this
update), as a dialog. The background check is not wired up on macOS yet;
the manual route works today.

Wherever the helper asks, the question has the same three answers: Update,
Cancel, and Ignore this update. Ignoring records the exact version beside
the install (the `.update-patcher.json` marker's `ignored` field); the
daily background check then stays silent about that version, and the next
patched release asks normally again. Installing a version clears an ignore
of that same version. `apply -Yes` (Windows) or `apply --yes` (Linux and
macOS) skips every question and installs even an ignored version.

The helper keeps its own record next to the install (`.update-patcher.json`)
and a log in your profile folder (`%LocalAppData%\PrismPatcher` on Windows,
`~/.local/share/prism-patcher` elsewhere). Delete both and it forgets
everything. If the official updater replaced the launcher in between, the
helper notices, says so, and puts the newest patched build back on top -
exactly the routine from the version-jump section above. Backups
(`*.bak-...`) accumulate next to the install; delete old ones by hand.

---

## When a new launcher version comes out

Two different situations:

**Within the same version line** (11.1.0 to 11.1.1): the new
`PrismLauncher.exe` from your copy's Releases pastes straight into your
existing folder and works. Done.

**Across a version jump** (for example 11.x to 12.0), the launcher's Qt
runtime files grow a version along with the exe - and this template ships
only exe-level releases for Windows, never Qt runtime files. The
recommended order:

1. **Let the official update go first.** Use the launcher's own *Check for
   Updates*, accept its update prompt, or run the official installer over
   the old install. That update rights everything that belongs together -
   exe, Qt runtime files, plugins - because the thing that owns the folder
   does the folder. Your accounts and instances are untouched, and a
   `backup_<version>` folder with the old app files appears automatically
   as a rollback. Until step 2 happens your launcher simply behaves like
   the official one: the offline patch is the only thing on pause.
2. **Paste the patched exe of the new version** once your copy has built it
   (within a day of the upstream release, or sooner with a manual run),
   exactly like the usual routine.

If the built-in update lands before your copy has built the new version,
nothing is broken: you are briefly on the official release, unpatched but
fully working, and the paste waits for step 2. The updater's dialog also
carries a **Skip** button if you would rather turn the offer down until the
patched build exists.

One thing the built-in updater cannot do is refresh a folder's Qt runtime
*without* going through the official build - and that is by design: the
template ships the exe only, and the official release is what owns and
rights the runtime files. The official update in step 1 is therefore the
procedure, not advice you may skip: run it first (the built-in updater,
or the official installer from https://prismlauncher.org when updating
by hand), and the patched exe of step 2 pastes on top of a folder that
is already the right shape.

> If a freshly pasted exe refuses to start (it closes instantly, or an error
> names a `Qt6*.dll`): the folder's Qt runtime is older than the exe. That
> is the version-jump situation above, not a broken patch - the official
> update is what refreshes those files, then the paste follows.

## If a run turns red

A failed run shows up in the repository's **Actions** tab with a red X next to
the run. Two fixes cover almost everything:

- **The patch no longer applies** (upstream edited the same lines of code).
  No broken build gets published - the run simply stops. Updated patches are
  published on the template, and the *Template update available* issue is how
  you find out (see the next section); sync it in, then rerun. As a stopgap
  you can rerun the workflow with `upstream_ref` pinned to the last tag that
  worked.
- **A network hiccup** (Qt download, GitHub API). Just rerun the workflow.
- **The update helper failed its self-test** (kit 21). Before publishing, a
  run now also drives the helper on real runners on every platform that
  was built; a failure holds the release back and turns the run red. Rerun
  once - a flaky runner does happen - and if it repeats, the failing check
  is named in the `updater-selftest` job's log. The release publishes only
  after the helper passes.

---

## Keeping your copy in step with the template

At the end of every run there is a small check: the number in `KIT-VERSION`
in this repository is compared against the same file on the template. When
the template has moved ahead - newer patches, workflow fixes, doc
improvements - one issue titled **Template update available** is filed in
this repository describing the update. Later runs neither duplicate nor
spam it: the same open issue just gets a dated status comment, and it
closes itself once the versions match again.

**Out of date means paused, not broken (kit 12).** While this copy is
behind the template, its own build workflow skips the build entirely -
on purpose, so no run ever publishes a release built from an old kit.
The skip is loud on purpose too: the run's log carries a **"BUILDS
SKIPPED"** banner, a warning annotation and a line in the run summary,
the update issue says the same, and the run itself stays green. Nothing
needs deleting or reverting; syncing turns the builds back on.

**Taking the update - the one-click way.** Open the **Actions** tab, click
**"Sync kit files from template"** in the left list, press **"Run
workflow"**, confirm. The build's own automation account replaces the kit
files with the template's current copies, commits and pushes them, and any
open update notice closes on the spot - no terminal, no git. To get the
new version's launcher compiled immediately, run
**"Build patched Prism Launcher"** once after it; otherwise the next
scheduled run does it anyway.

One GitHub rule sits on top of the button: pushes that change workflow
files cannot be made by a repository's automatic bot token, and every
sync carries workflow files - GitHub does not even let that token hold
the "workflows" permission. So the one-click sync needs a **one-time
token setup**: create a fine-grained personal access token (only this
repository; Permissions **Contents: Read and write** and **Workflows:
Read and write**), save it as the repository secret `KIT_PUSH_TOKEN`,
and then press the button as above. The *Template update available*
issue spells the steps out. Copies still on kit 9 or older reach kit 10
by the terminal route below first - their button predates this logic -
and from kit 10 on every one-click works.

The issue also carries a terminal route that needs no token at all (the
four sync commands, plus the two rescue recipes seen in practice: a remote
name that already exists, and a push rejected because this repository's
heartbeat commits moved ahead of an older clone).

The details, condensed:

- The check runs at the very start of a run, in parallel with everything
  else, and fails soft. An out-of-date copy is told within the first minute
  of a run instead of after the compiler finishes; if the check itself
  misbehaves, the build is untouched and the only trace is a warning line in
  the job log plus a note in the run summary.
- An in-step copy files nothing and stays otherwise silent. A copy that
  lacks `KIT-VERSION` (bootstrapped before this check existed) reads as
  "not recorded" and therefore counts as behind until it syncs once.
- The sync button only runs when you press it; nothing about a copy updates
  itself without an explicit click (or, for the terminal route, an explicit
  push).
- Not interested in the nudges? Set the repository **variable**
  `KIT_UPDATES_OFF` to `true` (Settings > Secrets and variables > Actions >
  Variables) and the check disappears from every future run. Closing the
  issue without syncing is not an opt-out - the next run simply files a
  fresh one; the variable is the real off switch. Note that it silences
  the *notice* only: the pause on out-of-date builds still applies. The
  one documented bypass is the repository variable `build_if_old` = `true`
  (an emergency hatch for "I need a build even while behind").

The update replaces the template's copies of the whole kit -
`.github/workflows/`, `patches/`, `scripts/`, `docs/`, `updater/`,
`README.md`, `MAINTAINING.md` and `KIT-VERSION` - while touching nothing else in the
repository, including the `.state/` bookkeeping the runs maintain.

---

## Advanced notes

### What the patch changes

Four patches, all public files under `patches/` and shipped verbatim in every
release's `source-patches-<tag>.patch`:

- **001 - offline account creation** (`patches/001-disable-offline-gate.patch`):
  the *Add offline account* button works without any Microsoft account.
  Upstream checks `AccountList::anyAccountIsValid()` inside
  `AccountListPage::on_actionAddOffline_triggered()` before it opens the
  dialog; the patch removes that call. Creating an offline profile is a
  purely local operation - a UUID derived from `OfflinePlayer:<name>` and a
  placeholder token - and never contacts Microsoft.
- **002 - offline launching** (`patches/002-offline-launch.patch`): launch
  with an offline account picked and the game starts in offline mode instead
  of demo mode - the "you must have at least one Microsoft account" dialog is
  gone. With an all-offline list, the instance page's *Download All* button
  works again (it fetches the same public game files an online launch would -
  offline launches never download by themselves) and the first-run
  "Add Microsoft account" wizard page is skipped.
- **003 - account picker** (`patches/003-offline-account-picker.patch`):
  launch with nothing picked and an all-offline list, and instead of the
  "you must have a Microsoft account... open the account manager?" dead end
  you get the stock account picker - the same *Which account would you like
  to use?* dialog upstream shows when valid accounts exist but none is set
  as default - with your offline accounts in it. Pick one and go.
- **004 - offline launch auto-fetch** (`patches/004-offline-auto-fetch.patch`):
  when an offline launch would stop on missing game files and the list is
  all-offline, the launch downloads what is missing - the same public file
  downloads an online session runs at launch time (libraries, assets) - and
  then starts the game. It works on the first launch of a fresh install too.
  A fully cached launch still runs with no internet at all and downloads
  nothing. A download that cannot complete fails the launch with the stock
  offline message - there is never a half-fetched launch.

The one rule across all four: with a Microsoft account selected - or merely
present in the list - everything is byte-for-byte stock, including Microsoft
accounts that do not own Minecraft (stock dialog, stock demo flow) and all
installing, signing in, and account-list behavior. The picker and auto-fetch
reliefs switch on only when every account in the list is offline; empty
lists are untouched.

`Qt6NetworkAuth.dll` is left alone - no gate ever lived in it; the file is only
present because the launcher links Qt's OAuth helper for its genuine Microsoft
login feature.

One line belongs next to them: **the four patches are the whole diff.** No
updater, no telemetry, no phone-home is ever added to the launcher - the
binaries a run produces are the upstream source with exactly these patches
on top and nothing else. The optional update helper is a separate script
you download from the Releases page and run yourself; it lives beside the
release, never inside the launcher (see *Updating with the helper*).

### How the pipeline decides what to build

> **Where releases appear.** On the template itself, a scheduled run only
> verifies that the patch still applies to upstream and updates its
> bookkeeping - nothing is published here. In a copy created with **Use this
> template**, the same run publishes a release in *that* repository. The
> switch is the repository variable `no_binaries` - see MAINTAINING.md.

1. On every scheduled run (06:23 UTC daily) the workflow fetches upstream
   releases and compares them with `.state/last-build.json`.
2. It releases the newest upstream **stable** tag it has not handled yet
   (marked *Latest*), and separately the newest **`-preN`** tag - but only if
   that pre-release is newer than the newest stable being handled (marked
   *Pre-release*), mirroring how upstream marks them.
3. Each build clones the chosen tag, applies `patches/*.patch` in sorted
   (numbered) order, and reads the tag's own CI configuration to build each
   platform the way the official build of that tag does: same runner, Qt
   version, compiler setup and CMake preset, per platform.
4. Assets per release: one file per platform - the Windows exe, the Linux
   AppImage, and the macOS pair (DMG plus bare `prismlauncher-macos`
   binary) - plus `source-patches-<tag>.patch` (the exact source diff
   applied), one `checksums.txt` covering every file, and the update
   helper's plain scripts under `update-*` (see *Updating with the
   helper*). Nothing else is shipped. (Kit 9 deliberately dropped the old
   portable zip and tarball attachments; the install tutorials and the
   version-jump section above carry the reasoning.)
5. If nothing upstream changed and the patches are unchanged, the run only
   updates its state file and stops - no build, no release, no spam.

### Workflow inputs

| Input | Meaning |
|---|---|
| `upstream_ref` | Build a specific upstream tag or branch (e.g. `11.1.1`, `develop`). Empty = automatic tracking. |
| `qt_version` | Force a Qt version instead of the tag's own (leave empty). |
| `force_rebuild` | Rebuild and overwrite the release for a tag that already exists here. |

You can silence the automatic schedule by deleting the `schedule:` block in
`.github/workflows/build-patched.yml`, then run everything manually.

### Writing your own patch

Patches are ordinary unified diffs against an upstream tag. Recipe:

```
git clone --depth 1 --branch <TAG> https://github.com/PrismLauncher/PrismLauncher prism
# edit files inside prism/ as you like
cd prism
git diff > ../patches/002-my-change.patch
```

Rules that keep the pipeline honest:

- Name them `001-...`, `002-...`; they are applied in sorted order onto a clean
  upstream clone.
- Save with LF line endings (`.gitattributes` here enforces that).
- Every patch must apply to a **fresh clone** - not to the result of the
  previous one unless you really intend to build on it.
- Run the workflow afterwards; you get your customized exe in Releases.

### Repository map

| Path | Purpose |
|---|---|
| `patches/` | the patch set applied to every build |
| `updater/` | the optional update helper - plain scripts shipped as release assets, never built into the launcher |
| `.github/workflows/build-patched.yml` | the whole pipeline, helper self-test included |
| `.github/workflows/sync-from-template.yml` | the one-click update button (manual only) |
| `scripts/` | decision + bookkeeping + sync + helper self-test helpers (plain PowerShell) |
| `.state/last-build.json` | which tags the automation has handled so far |
| `docs/fingerprint.txt` | provenance values for verifying bundles you produced |
| `MAINTAINING.md` | notes for tending the template branch itself |

## License

Same as upstream: **GPL-3.0-only** (`LICENSE` here). Any exe built with this
template comes from an upstream source tag with the attached
`source-patches-<tag>.patch` applied - that combination is all you need to
rebuild it from scratch. This is a personal-use template: enjoy it yourself,
and don't strip the attribution when sharing the patch files. Note that
Mojang's *online-mode* servers enforce their own authentication server-side;
this affects the launcher's account handling only.
