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
it, and the patched builds - the Windows exe (drop-in for the official one), a
Windows portable zip, the Linux AppImage and portable tarball, and the macOS
DMG, each packaged the way the official releases are - plus the exact source
patch land in *your own copy's* Releases tab when you run it there. That makes
the whole thing easy to read and easy to extend: a patch is one plain-text
file.

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
Launcher folder (for example `%AppData%\PrismLauncher` or wherever the portable
copy lives), and paste it in, replacing the old one. **Keep a copy of the
original exe first.** Not on Windows? Jump to *What gets built, and where*
below - the Linux and macOS bundles are installed differently, and all of it
is described there.

After that you do nothing. When the launcher team publishes a new version, a
fresh patched build shows up in your Releases within a day - for every
platform your copy builds.

## What gets built, and where

Every upstream version produces one release in your copy containing, for the
flagship flavour of each platform (the same one the official release leads
with):

| File | For | How to use it |
|---|---|---|
| `PrismLauncher.exe` | Windows | paste it over the official `prismlauncher.exe` (the two steps of *The easy way*) |
| `PrismLauncher-Windows-MSVC-Portable-<tag>.zip` | Windows | a full launcher folder (exe + Qt runtime), unpack into a fresh folder and run |
| `PrismLauncher-Linux-x86_64-<tag>.AppImage` | Linux, Steam Deck | make it executable (`chmod +x`) and run it |
| `PrismLauncher-Linux-Qt6-Portable-<tag>.tar.gz` | Linux, Steam Deck | extract into a folder, run the launcher inside `bin/` |
| `PrismLauncher-macOS-<tag>.dmg` | macOS | open it, drag the app to Applications |
| `source-patches-<tag>.patch` + `checksums.txt` | all | the exact source diff applied, and the expected checksums of every file |

Notes worth having in writing:

- **Nothing is signed.** This kit holds no vendor signing credentials, so the
  Windows builds are unsigned (SmartScreen may warn: *More info* then *Run
  anyway*, after checking the checksum), the macOS build is ad-hoc signed
  (Gatekeeper asks on first launch: right-click the app and choose *Open*),
  and the Linux builds are unsigned. `checksums.txt` is the integrity check
  to use instead.
- **Steam Deck**: switch to desktop mode, download the AppImage, make it
  executable, run it - and optionally use *Add to Steam* from its program
  menu. This is not the Flathub build: upstream's official Flathub channel
  continues to exist on its own and is untouched by this template.
- **The in-app updater only knows official builds** (that is exactly what
  the version-jump section below relies on). Updating a *patched* install
  means replacing its files from your own Releases.
- **Need fewer platforms?** macOS runners cost about 10x the minutes on
  private repositories (Windows 2x, Linux 1x; all three are free on public
  repositories). Set the repository **variable** `platforms` (same place as
  `no_binaries`) to any of `windows`, `linux`, `macos` - comma or space
  separated, or leave it unset for all three.

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

One thing the built-in updater cannot do is refresh a folder whose Qt
runtime is too old *without* going through the official build. If you are
offline when a version jump happens: download the
`PrismLauncher-Windows-MSVC-Portable-<tag>.zip` of the new version from your
copy's Releases - it is a complete patched folder (launcher plus fresh Qt
runtime) - unpack it into a fresh folder, move your instances and
`accounts.json` in, done. Later releases within the line go back to the
ordinary paste-in routine.

> If a freshly pasted exe refuses to start (it closes instantly, or an error
> names a `Qt6*.dll`): the folder's Qt runtime is older than the exe. That
> is the version-jump situation above, not a broken patch - the official
> update (or the portable zip route) is what refreshes those files.

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

---

## Keeping your copy in step with the template

At the end of every run there is a small check: the number in `KIT-VERSION`
in this repository is compared against the same file on the template. When
the template has moved ahead - newer patches, workflow fixes, doc
improvements - one issue titled **Template update available** is filed in
this repository describing the update. Later runs neither duplicate nor
spam it: the same open issue just gets a dated status comment, and it
closes itself once the versions match again.

**Taking the update - the one-click way.** Open the **Actions** tab, click
**"Sync kit files from template"** in the left list, press **"Run
workflow"**, confirm. The build's own automation account replaces the kit
files with the template's current copies, commits and pushes them, and any
open update notice closes on the spot - no terminal, no git. To get the
new version's launcher compiled immediately, run
**"Build patched Prism Launcher"** once after it; otherwise the next
scheduled run does it anyway.

The issue also carries a terminal route for anyone who prefers it (the
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
  fresh one; the variable is the real off switch.

The update replaces the template's copies of the whole kit -
`.github/workflows/`, `patches/`, `scripts/`, `docs/`, `README.md`,
`MAINTAINING.md` and `KIT-VERSION` - while touching nothing else in the
repository, including the `.state/` bookkeeping the runs maintain.

---

## Advanced notes

### What the patch changes

Four patches, all public files under `patches/` and shipped verbatim in every
release's `source-patches-<tag>.patch`:

- **001 - offline account creation** (`patches/001-disable-offline-gate.patch`):
  upstream refuses to open the *Add offline account* dialog unless at least one
  Microsoft account in your list owns Minecraft
  (`AccountListPage::on_actionAddOffline_triggered()` calls
  `AccountList::anyAccountIsValid()`; the patch removes the call). That check
  is purely a client-side
  convention: creating an offline profile is a completely local operation (a
  UUID derived from `OfflinePlayer:<name>` and a placeholder token) and never
  contacts Microsoft. The patch removes that one gate.
- **002 - offline launching** (`patches/002-offline-launch.patch`): with an
  offline account *selected* for the launch, the "you must have at least one
  Microsoft account" dialog is skipped and the launch runs in offline mode
  instead of being routed into demo mode. And when *every* account in your
  list is offline, the instance page's *Download All* button works again (it
  fetches the publicly distributed game files an offline launch needs -
  offline launches never download by themselves) and the first-run
  "Add Microsoft account" wizard page is skipped.
- **003 - account picker fallback** (`patches/003-offline-account-picker.patch`):
  when nothing is selected for a launch and *every* account in your list is
  offline, upstream shows a dead end ("you must have a Microsoft account...
  open the account manager?"). The patch opens the stock account picker
  instead - the very same *Which account would you like to use?* dialog
  upstream shows when valid accounts exist but none is set as default - with
  your offline accounts listed, so you just pick one and go. Empty lists, and
  lists containing any Microsoft account, keep the stock dialog.
- **004 - offline launch auto-fetch** (`patches/004-offline-auto-fetch.patch`):
  when an offline launch would stop on missing libraries and *every* account
  in your list is offline, the launch itself downloads what is missing and
  then starts the game. The decision is made inside the existing
  "ensure libraries" step, after the launcher has resolved the instance's
  version metadata, so it works even on the first launch of a freshly started
  launcher: an empty library check at that moment would otherwise miss every
  file. The downloads are the same public file downloads an online session
  runs at launch time (libraries, assets). Fully cached launches stay silent
  and touch nothing, any list containing a Microsoft account keeps stock
  behavior, and a download that cannot complete fails the launch with the
  stock offline message - there is never a half-fetched launch.

That is the complete list. The rule underneath all four: whenever a Microsoft
account is selected - or merely present in the list - everything is
byte-for-byte stock, including Microsoft accounts that do not own Minecraft
(stock dialog, stock demo flow) and all installing, signing in, and
account-list behavior. The account-picker and auto-fetch reliefs only switch
on when *every* account in the list is offline; empty lists are untouched.

`Qt6NetworkAuth.dll` is left alone - no gate ever lived in it; the file is only
present because the launcher links Qt's OAuth helper for its genuine Microsoft
login feature.

### How the pipeline decides what to build

> **Where releases appear.** On the template itself, a scheduled run only
> verifies that the patch still applies to upstream and updates its
> bookkeeping - nothing is published here. In a copy created with **Use this
> template**, the same run publishes a release in *that* repository. The
> switch is the repository variable `no_binaries` - see MAINTAINING.md.

1. On every scheduled run (06:00 UTC daily) the workflow fetches upstream
   releases and compares them with `.state/last-build.json`.
2. It releases the newest upstream **stable** tag it has not handled yet
   (marked *Latest*), and separately the newest **`-preN`** tag - but only if
   that pre-release is newer than the newest stable being handled (marked
   *Pre-release*), mirroring how upstream marks them.
3. Each build clones the chosen tag, applies `patches/*.patch` in sorted
   (numbered) order, and reads the tag's own CI configuration to build each
   platform the way the official build of that tag does: same runner, Qt
   version, compiler setup and CMake preset, per platform.
4. Assets per release: one binary bundle per platform (the Windows exe plus
   the Windows portable zip, the Linux AppImage plus portable tarball, the
   macOS DMG), `source-patches-<tag>.patch` (the exact source diff applied),
   and one `checksums.txt` covering every file. Nothing else is shipped.
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
| `.github/workflows/build-patched.yml` | the whole pipeline |
| `.github/workflows/sync-from-template.yml` | the one-click update button (manual only) |
| `scripts/` | decision + bookkeeping + sync helpers (plain PowerShell) |
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
