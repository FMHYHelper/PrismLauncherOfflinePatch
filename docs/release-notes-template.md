Prism Launcher {{TAG}} - offline-patched build (personal-use template)

Built from the launcher's own upstream source - [tag {{TAG}}]({{UPSTREAM_URL}}) - plus the four small patches below. Everything the patches do not touch behaves exactly like the official release of that version.

## What was changed

1. **Offline account creation** (`patches/001-disable-offline-gate.patch`). The *Add offline* button now works without any Microsoft/Mojang account: the launcher no longer demands a signed-in account that owns the game before it opens the dialog. Creating an offline profile is a purely local operation (a UUID derived from `OfflinePlayer:<name>` and a placeholder token) and never contacts Microsoft.

2. **Offline launching** (`patches/002-offline-launch.patch`). Launch with an offline account picked and the game starts in offline mode instead of demo mode - the "you must have at least one Microsoft account" dialog is gone. With an all-offline account list, the instance page's "Download All" button works again (it fetches the same public game files an online launch would - offline launches never download anything by themselves) and the first-run "Add Microsoft account" wizard page is skipped.

3. **Account picker** (`patches/003-offline-account-picker.patch`). Launch with nothing picked and an all-offline account list, and instead of the "you must have a Microsoft account" dead end you get the normal account picker - pick an account and launch. An empty list, or any list containing a Microsoft account, keeps the stock dialog.

4. **Offline launch auto-fetch** (`patches/004-offline-auto-fetch.patch`). When an offline launch would stop on missing game files and the account list is all-offline, the launch downloads what is missing first (libraries, assets - the same public downloads an online launch runs) and then starts the game. It works on the first launch of a fresh install as well. A fully cached launch still runs with no internet at all. A download that cannot complete fails the launch with the stock offline message - there is never a half-fetched launch.

The rule across all four: select any Microsoft account and the launcher behaves exactly like the official build - stock dialog, stock demo flow, even for Microsoft accounts that do not own Minecraft. The picker and auto-fetch reliefs switch on only when every account in the list is an offline account; empty lists are untouched. Adding accounts, signing in, and the account list itself are untouched.

## Platform builds

Every platform the official release supports is built from the same tag, each with the compiler and Qt configuration the official build of that platform uses (read from the tag's own CI files). None of the builds carry a vendor code signature - this kit holds no signing credentials on any platform - so the integrity check to use is `checksums.txt` below.

- **Windows** (`PrismLauncher.exe`): drop-in replacement for the `prismlauncher.exe` inside an existing official install; see the steps under Install below. Windows SmartScreen may warn about an unsigned exe - "More info", then "Run anyway" after checking the checksum.
- **Linux / Steam Deck** (`PrismLauncher-Linux-x86_64.AppImage`): one self-contained file, named exactly like the official AppImage it replaces - keep a backup of the original (rename it to `.bak`), drop the patched file in its place, and your menu entry or Steam shortcut keeps working untouched. It carries its own Qt runtime, so unlike Windows there is no version-jump dance at all. Make it executable (`chmod +x`) if the browser stripped that, then run it. On a Steam Deck, desktop mode.
- **macOS, full app** (`PrismLauncher-macOS-{{TAG}}.dmg`): the easy route - open it and drag the app to Applications, replacing the official copy. Ad-hoc signed on macOS 12 and newer; Gatekeeper asks on the first launch - right-click the app and choose *Open*, or use *Open Anyway* under System Settings > Privacy & Security on Apple Silicon.
- **macOS, drop-in binary** (`prismlauncher-macos`): the bare patched universal binary, for an existing official installation. Replace the official `prismlauncher` inside the app's `Contents/MacOS` (keep a backup of the original). Apple refuses the first launch of the swapped bundle - signature behavior, not corruption - so re-sign the bundle once with `codesign --force --deep -s - "/Applications/Prism Launcher.app"`.

## Install

Official first, patched file second - the same order on every platform:

1. Have the official release of the same version installed the ordinary way (Windows installer or official portable zip; the upstream AppImage; the official DMG), and quit the launcher if it is running.
2. Put this release's file on top:
   - Windows: replace the official `prismlauncher.exe` with the attached `PrismLauncher.exe`, keeping a backup of the original.
   - Linux: replace the official AppImage file with the attached one (same name - keep a backup of the original first, and `chmod +x` the new file if the browser stripped the bit).
   - macOS: drag the DMG over Applications, or swap the attached `prismlauncher-macos` into `Contents/MacOS` of the official app and run the re-sign line above.
3. The launcher afterwards is yours to configure; the built-in updater may offer official builds later - take the official update first (it rights the runtime files on big version jumps), then re-apply this release's patched file.

## Provenance

- Base source: the upstream tag above (shallow clone pinned to the tag).
- Patch set: exactly the text in the attached `source-patches-{{TAG}}.patch` (the publicly readable files under `patches/`, concatenated).
- Sha256 of every file: `checksums.txt`.
- Compiler and Qt versions: per platform, the same recipe the official build of that tag uses (read from the tag's own CI configuration).

License: GPL-3.0-only, same as upstream. Rebuild with the upstream source and the attached patch. Personal use - don't ship this as your own launcher.
