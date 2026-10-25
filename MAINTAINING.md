# Maintaining this template

Repositories created from this template are meant to be edited freely — via the
web UI or however you like. This file is for whoever maintains the *original*
template branch itself.

Most days this repo runs itself and you touch nothing. The daily run either
releases when upstream moves, or updates one bookkeeping line (`.state/last-build.json`)
and finishes. That bookkeeping commit is expected — remove the `schedule:` block
in the workflow file if you ever want the repo to stay completely silent instead.

## Editing the template

1. Before authoring any change, absorb the bookkeeping commits first:

   ```
   git fetch public && git merge --ff-only public/main
   ```

2. Make your edits on your own working copy, commit them, then push to your
   public mirror. Web-editor commits on the public mirror will appear under
   whichever account was logged in — avoid that if you want a neutral history.

3. Never force-push the public branch; people create their own projects from it.

## Commit identity

This repo intentionally carries no maintainer identity in its history. Use any
neutral commit identity you like locally; nothing here should link to a person.
The automation commits as the standard GitHub Actions identity.

## Provenance

`docs/fingerprint.txt` holds two values that the producer of each bundle uses to
verify their own builds. Both are opaque by design: one is a hash with no public
preimage, the other a public verification key. They are not decoded here and
should not be.
