Prism Launcher {{TAG}} — offline-patched build (personal-use template)

Built from the launcher's own upstream source at
{{UPSTREAM_URL}}
with the small, fully disclosed patch set below. Everything not described
there behaves exactly like the official release of that version.

What was changed — full disclosure
----------------------------------

1. **Offline account creation** (`patches/001-disable-offline-gate.patch`).
   Creating an *offline* account no longer requires a signed-in
   Microsoft/Mojang account that owns the game. The removed check was purely
   client-side: creating an offline profile is a local operation (a UUID
   derived from `OfflinePlayer:<name>` and a placeholder token) that never
   contacts Microsoft.

2. **Offline launching** (`patches/002-offline-launch.patch`). When the
   account selected for the launch — the one the launcher would actually use —
   is an *offline* account, the "you must have at least one Microsoft account"
   dialog is skipped and the game launches in offline mode instead of being
   routed into demo mode. Separately, when *every* account in the list is an
   offline account, the instance page's "Download All" button works again —
   it fetches the publicly distributed game files an offline launch needs
   (offline launches never download anything by themselves) — and the
   first-run "Add Microsoft account" wizard page is skipped.

3. **Account picker fallback** (`patches/003-offline-account-picker.patch`).
   When no account is selected for a launch and *every* account in the list
   is an offline account, the stock "you must have a Microsoft account"
   dialog is replaced with the stock account picker (offline accounts
   included) so you choose the account to launch with. Empty lists, and
   lists containing any Microsoft account, keep the stock dialog.

4. **Offline launch auto-fetch** (`patches/004-offline-auto-fetch.patch`).
   When an offline launch would stop on missing libraries and *every*
   account in the list is an offline account, the launch first runs the
   same public downloads an online session runs at launch time (version
   metadata, libraries, assets) and then starts the game. Fully cached
   launches, and launches with any Microsoft account in the list, are
   unchanged; without internet the launch fails the way an online launch
   would, and a partial fetch never ends in a half-instanced launch.

That is the complete list of differences. Launch decisions key off the
account actually being used: whenever a Microsoft account is selected, the
launcher behaves exactly like the official build — including Microsoft
accounts that do not own Minecraft (they still get the stock dialog and the
stock demo flow) — and all installing, signing in, and account-list behavior
remains untouched. The account-picker and auto-fetch reliefs only apply when
every account in the list is offline; empty lists are untouched.

The exe is named `PrismLauncher.exe` — the same name the official build uses —
so it is a drop-in replacement.

Install
-------

1. Take the official **Windows-MSVC** release of the same version
   (portable zip or installer — either) if you don't have it already.
2. Replace its `prismlauncher.exe` with the `PrismLauncher.exe` attached here
   (keep a backup of the original).
3. The launcher afterwards is yours to configure; the built-in updater may
   offer official builds later — accept it and re-apply this patched exe.

Provenance
----------

- Base source: upstream tag above (shallow clone pinned to the tag).
- Patch set: exactly the text in the attached `source-patches-{{TAG}}.patch`
  (the publicly readable files under `patches/`, concatenated).
- Sha256 of every file: `checksums.txt`.
- Compiler and Qt version: the same recipe the official Windows-MSVC build
  of that tag uses (read from the tag's own CI configuration).

License: GPL-3.0-only, same as upstream. Rebuild with upstream source +
attached patch. Personal use — don't ship this as your own launcher.
