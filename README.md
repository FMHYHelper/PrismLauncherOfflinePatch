# Prism Launcher Offline-Patch Template

A tiny repository that runs one job on autopilot: it checks
[Prism Launcher](https://github.com/PrismLauncher/PrismLauncher) upstream
releases daily and keeps a small, fully disclosed patch set in step with them
— it removes the client-side checks that gate offline accounts (creating one,
and launching with one selected). Nothing else about the launcher is modified.

**This repository hosts no binaries.** It is the tool, not the distribution:
no launcher code is stored here. Every build starts from a fresh clone of an
upstream release tag, your patch files from `patches/` are applied on top of
it, and the patched `PrismLauncher.exe` (drop-in for the official one) plus
the exact source patch land in
*your own copy's* Releases tab when you run it there. That makes the whole
thing easy to read and easy to extend: a patch is one plain-text file.

---

## The easy way (5 steps, about 40 minutes once)

**Step 1.** On this page, click the green **"Use this template"** button (top
right), then **"Create a new repository"**. Name it anything you like and click
**Create repository**.

**Step 2.** In your new repository open **Settings → Actions → General**. At the
bottom, under **Workflow permissions**, choose **Read and write permissions** and
click **Save**.

**Step 3.** Click the **Actions** tab. If a banner asks you to confirm, click the
button to enable workflows.

**Step 4.** Still in Actions, click **"Build patched Prism Launcher"** on the
left, then **"Run workflow" → "Run workflow"**. Wait about 40 minutes — it is
compiling the launcher from real source code.

**Step 5.** Open the **Releases** page **of your own new repository**. Download
**`PrismLauncher.exe`** (the only `.exe` there), open your existing Prism
Launcher folder (for example `%AppData%\PrismLauncher` or wherever the portable
copy lives), and paste it in, replacing the old one. **Keep a copy of the
original exe first.**

After that you do nothing. When the launcher team publishes a new version, a
fresh patched exe shows up in your Releases within a day.

> The patched exe matches the **Windows-MSVC** flavour of the official release
> of the same version. Other official flavours exist (Linux AppImage, MinGW,
> macOS) — this template builds the flagship Windows one.

---

## When a new launcher version comes out

Within the same version line (for example 11.1.0 → 11.1.1) the new exe pastes
straight into your existing folder and works.

Across a version jump (for example 11.x → 12.0) the Qt runtime files inside an
old folder may be too old for the new exe. In that case do it once: download the
official **PrismLauncher-Windows-MSVC-…-Portable.zip** of the new version,
drop in your account data, then return to the paste-in-the-exe routine for later
12.x releases.

The launcher's built-in updater may at some point offer the official update.
Accepting it replaces the exe with the official one — simply paste the patched
exe from your own repository's Releases again afterwards.

## If a run turns red

A failed run shows up in the repository's **Actions** tab with a red ✗ next to
the run. Two fixes cover almost everything:

- **The patch no longer applies** (upstream edited the same lines of code).
  No broken build gets published — the run simply stops. Either wait for an
  updated patch in `patches/`, remove the failing patch, or rerun the workflow
  with `upstream_ref` pinned to the last tag that worked.
- **A network hiccup** (Qt download, GitHub API). Just rerun the workflow.

---

## Advanced notes

### What the patch changes

Two patches, both public files under `patches/` and shipped verbatim in every
release's `source-patches-<tag>.patch`:

- **001 — offline account creation** (`patches/001-disable-offline-gate.patch`):
  upstream refuses to open the *Add offline account* dialog unless at least one
  Microsoft account in your list owns Minecraft
  (`AccountListPage::on_actionAddOffline_triggered()` →
  `AccountList::anyAccountIsValid()`). That check is purely a client-side
  convention: creating an offline profile is a completely local operation (a
  UUID derived from `OfflinePlayer:<name>` and a placeholder token) and never
  contacts Microsoft. The patch removes that one gate.
- **002 — offline launching** (`patches/002-offline-launch.patch`): with an
  offline account *selected* for the launch, the "you must have at least one
  Microsoft account" dialog is skipped and the launch runs in offline mode
  instead of being routed into demo mode. And when *every* account in your
  list is offline, the instance page's *Download All* button works again (it
  fetches the publicly distributed game files an offline launch needs —
  offline launches never download by themselves) and the first-run
  "Add Microsoft account" wizard page is skipped.

That is the complete list. Launch decisions key off the account actually being
used: whenever a Microsoft account is selected — or merely present in the
list — everything is byte-for-byte stock, including Microsoft accounts that do
not own Minecraft (stock dialog, stock demo flow) and all installing, signing
in, and account-list behavior.

`Qt6NetworkAuth.dll` is left alone — no gate ever lived in it; the file is only
present because the launcher links Qt's OAuth helper for its genuine Microsoft
login feature.

### How the pipeline decides what to build

> **Where releases appear.** On the template itself, a scheduled run only
> verifies that the patch still applies to upstream and updates its
> bookkeeping — nothing is published here. In a copy created with **Use this
> template**, the same run publishes a release in *that* repository. The
> switch is the repository variable `no_binaries` — see MAINTAINING.md.

1. On every scheduled run (06:00 UTC daily) the workflow fetches upstream
   releases and compares them with `.state/last-build.json`.
2. It releases the newest upstream **stable** tag it has not handled yet
   (marked *Latest*), and separately the newest **`-preN`** tag — but only if
   that pre-release is newer than the newest stable being handled (marked
   *Pre-release*), mirroring how upstream marks them.
3. Each build clones the chosen tag, applies `patches/*.patch` in sorted
   (numbered) order, and reads the tag's own `.github/workflows/build.yml` to
   use the same Qt version, compiler setup and CMake preset the official
   builds use.
4. Assets per release: the patched exe, `source-patches-<tag>.patch` (the exact
   source diff applied), and `checksums.txt`. Nothing else is shipped.
5. If nothing upstream changed and the patches are unchanged, the run only
   updates its state file and stops — no build, no release, no spam.

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

- Name them `001-…`, `002-…`; they are applied in sorted order onto a clean
  upstream clone.
- Save with LF line endings (`.gitattributes` here enforces that).
- Every patch must apply to a **fresh clone** — not to the result of the
  previous one unless you really intend to build on it.
- Run the workflow afterwards; you get your customized exe in Releases.

### Repository map

| Path | Purpose |
|---|---|
| `patches/` | the patch set applied to every build |
| `.github/workflows/build-patched.yml` | the whole pipeline |
| `scripts/` | decision + bookkeeping helpers (plain PowerShell) |
| `.state/last-build.json` | which tags the automation has handled so far |
| `docs/fingerprint.txt` | provenance values for verifying bundles you produced |
| `MAINTAINING.md` | notes for tending the template branch itself |

## License

Same as upstream: **GPL-3.0-only** (`LICENSE` here). Any exe built with this
template comes from an upstream source tag with the attached
`source-patches-<tag>.patch` applied — that combination is all you need to
rebuild it from scratch. This is
a personal-use template: enjoy it yourself, and don't strip the attribution
when sharing the patch files. Note that Mojang's *online-mode* servers enforce
their own authentication server-side; this affects the launcher's account
handling only.
