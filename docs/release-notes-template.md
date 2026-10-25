Prism Launcher {{TAG}} — offline-patched build (personal-use template)

Built from the launcher's own upstream source at
{{UPSTREAM_URL}}
with one client-side check removed: creating an offline account no longer
requires a signed-in Microsoft/Mojang account that owns the game. Everything
else is identical to the official release of that version.

Install
-------

1. Take the official **Windows-MSVC** release of the same version
   (portable zip or installer — either) if you don't have it already.
2. Replace its `prismlauncher.exe` with the `.exe` attached here
   (keep a backup of the original).
3. The launcher afterwards is yours to configure; the built-in updater may
   offer official builds later — accept it and re-apply this patched exe.

Provenance
----------

- Base source: upstream tag above (shallow clone pinned to the tag).
- Patch set: exactly the text in the attached `source-patches-{{TAG}}.patch`.
- Sha256 of every file: `checksums.txt`.
- Compiler and Qt version: the same recipe the official Windows-MSVC build
  of that tag uses (read from the tag's own CI configuration).

License: GPL-3.0-only, same as upstream. Rebuild with upstream source +
attached patch. Personal use — don't ship this as your own launcher.
