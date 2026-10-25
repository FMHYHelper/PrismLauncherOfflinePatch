Prism Launcher {{TAG}} - offline-patched build (personal-use template)

Built from the launcher's own upstream source at
{{UPSTREAM_URL}}
with the small, fully disclosed patch set below. Everything not described
there behaves exactly like the official release of that version.

What was changed - full disclosure
----------------------------------

1. **Offline account creation** (`patches/001-disable-offline-gate.patch`).
   Creating an *offline* account no longer requires a signed-in
   Microsoft/Mojang account that owns the game. The removed check was purely
   client-side: creating an offline profile is a local operation (a UUID
   derived from `OfflinePlayer:<name>` and a placeholder token) that never
   contacts Microsoft.

2. **Offline launching** (`patches/002-offline-launch.patch`). When the
   account selected for the launch - the one the launcher would actually use -
   is an *offline* account, the "you must have at least one Microsoft account"
   dialog is skipped and the game launches in offline mode instead of being
   routed into demo mode. Separately, when *every* account in the list is an
   offline account, the instance page's "Download All" button works again -
   it fetches the publicly distributed game files an offline launch needs
   (offline launches never download anything by themselves) - and the
   first-run "Add Microsoft account" wizard page is skipped.

3. **Account picker fallback** (`patches/003-offline-account-picker.patch`).
   When no account is selected for a launch and *every* account in the list
   is an offline account, the stock "you must have a Microsoft account"
   dialog is replaced with the stock account picker (offline accounts
   included) so you choose the account to launch with. Empty lists, and
   lists containing any Microsoft account, keep the stock dialog.

4. **Offline launch auto-fetch** (`patches/004-offline-auto-fetch.patch`).
   When an offline launch would stop on missing libraries and *every*
   account in the list is an offline account, the launch downloads what is
   missing and then starts the game. The decision is made inside the
   existing "ensure libraries" step, after the launcher has resolved the
   instance's version metadata, so it works on the first launch of a
   freshly started launcher as well. The downloads are the same public
   file downloads an online session runs at launch time (libraries,
   assets). Fully cached launches stay silent, any Microsoft account in
   the list keeps stock behavior, and a download that cannot complete
   fails the launch with the stock offline message - there is never a
   half-fetched launch.

That is the complete list of differences. Launch decisions key off the
account actually being used: whenever a Microsoft account is selected, or
merely present in the list, the launcher behaves exactly like the official
build - including Microsoft accounts that do not own Minecraft (they still
get the stock dialog and the stock demo flow) - and all installing, signing
in, and account-list behavior remains untouched. The account-picker and
auto-fetch reliefs only apply when every account in the list is offline;
empty lists are untouched.

Platform builds
---------------

Every platform the official release supports is built from the same tag,
each with the compiler and Qt configuration the official build of that
platform uses (read from the tag's own CI files). None of the builds carry
a vendor code signature - this kit holds no signing credentials on any
platform - so the integrity check to use is `checksums.txt` below.

- **Windows** (`PrismLauncher.exe`): drop-in replacement for the
  `prismlauncher.exe` inside an existing official install; see the steps
  under *Install* below. Windows SmartScreen may warn about an unsigned
  exe - "More info" and "Run anyway" after checking the checksum.
- **Linux / Steam Deck**
  (`PrismLauncher-Linux-x86_64-{{TAG}}.AppImage`): one self-contained
  file - it replaces the official AppImage and carries its own Qt
  runtime, so unlike Windows it has no version-jump dance at all.
  Make it executable (`chmod +x`) if the browser stripped that, then
  run it. On a Steam Deck, desktop mode.
- **macOS - full app** (`PrismLauncher-macOS-{{TAG}}.dmg`): the easy
  route - open it and drag to Applications, replacing the official
  copy. Ad-hoc signed on macOS 12 and newer; Gatekeeper asks on the
  first launch - right-click the app and choose *Open*, or use *Open
  Anyway* under System Settings > Privacy & Security on Apple Silicon.
- **macOS - drop-in binary** (`prismlauncher-macos`): the bare patched
  universal binary, for an existing official installation. Replace the
  official `prismlauncher` inside the app's `Contents/MacOS` (keep a
  backup of the original); Apple refuses the first launch of the
  swapped bundle - signature behavior, not corruption - so re-sign the
  bundle once:

    codesign --force --deep -s - "/Applications/Prism Launcher.app"

Install
-------

Official first, patched file second - the same order on every platform:

1. Have the official release of the same version installed the ordinary
   way (Windows installer or official portable zip; the upstream
   AppImage; the official DMG), and quit the launcher if it is running.
2. Put this release's file on top:
   - Windows: replace the official `prismlauncher.exe` with the
     attached `PrismLauncher.exe`, keeping a backup of the original.
   - Linux: replace the official AppImage file with the attached one
     (and `chmod +x` it if the browser stripped the bit).
   - macOS: drag the DMG over Applications, or swap the attached
     `prismlauncher-macos` into `Contents/MacOS` of the official app
     and run the re-sign line above.
3. The launcher afterwards is yours to configure; the built-in updater
   may offer official builds later - take the official update first (it
   rights the runtime files on big version jumps), then re-apply this
   release's patched file.

Provenance
----------

- Base source: upstream tag above (shallow clone pinned to the tag).
- Patch set: exactly the text in the attached `source-patches-{{TAG}}.patch`
  (the publicly readable files under `patches/`, concatenated).
- Sha256 of every file: `checksums.txt`.
- Compiler and Qt versions: per platform, the same recipe the official
  build of that tag uses (read from the tag's own CI configuration).

License: GPL-3.0-only, same as upstream. Rebuild with upstream source +
attached patch. Personal use - don't ship this as your own launcher.
