#!/usr/bin/env bash
# update-patcher.sh - the update helper for the offline-patched Prism
# Launcher build on Linux (AppImage) and macOS (DMG app swap).
#
# This script is NOT part of the launcher. The patched launcher contains
# exactly the four published patches and nothing else - no updater, no
# phone-home - and that is a promise, not an accident: this helper lives
# outside the app and does, by hand, what a user could do by hand:
# download the newest patched build from a repository's Releases, check
# it against checksums.txt, back the old file up, and swap it in.
#
# Modes:
#   apply          interactive update (the default)
#   auto           non-interactive: update when needed, silent when current
#                  (the mode the optional background timer runs)
#   check          report only: installed version vs. latest release
#   enable-check   set up the optional daily background check
#                  (Linux: a systemd user timer; macOS: planned, not yet)
#   disable-check  remove the background timer again
#   status         show what is installed and what the timer is
#
# The source repository is baked in per release (the repo the asset came
# from). Override once with --repo owner/name. All it ever talks to is the
# GitHub API and download servers of that one repository.
#
# Files:
#   .update-patcher.json  - marker written next to the installed target
#   *.bak-<timestamp>     - backups; they accumulate, delete old ones by hand
#
# Usage:
#   bash update-patcher.sh [mode] [--repo owner/name] [--dir path]
#        [--app "/Applications/Prism Launcher.app"] [--source-dir path] [--yes]

set -u

MARKER=".update-patcher.json"
ASSET_LINUX="PrismLauncher-Linux-x86_64.AppImage"
STABLE="$HOME/.local/share/prism-patcher"
LOGFILE="$STABLE/update-check.log"
MODE="apply"
REPO='{{SOURCE_REPO}}'
DIR=""
APP=""
SRCDIR=""
TMPD=""
# globals the flow functions share:
TAG=""
ASSET_NAME=""
ASSET_URL=""
SUMFILE=""
TARGET=""
MAC_APP=""

cleanup() { if [ -n "$TMPD" ] && [ -d "$TMPD" ]; then rm -rf "$TMPD"; fi; }
trap cleanup EXIT

info() { printf '%s\n' "$*"; }
warn() { printf '  note: %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------- arguments ----

while [ $# -gt 0 ]; do
  case "$1" in
    apply|auto|check|enable-check|disable-check|status) MODE="$1"; shift ;;
    --repo)       [ $# -ge 2 ] || die "--repo needs a value";      REPO="$2";   shift 2 ;;
    --dir)        [ $# -ge 2 ] || die "--dir needs a value";       DIR="$2";    shift 2 ;;
    --app)        [ $# -ge 2 ] || die "--app needs a value";       APP="$2";    shift 2 ;;
    --source-dir) [ $# -ge 2 ] || die "--source-dir needs a value"; SRCDIR="$2"; shift 2 ;;
    --yes)        shift ;;
    *) die "unknown argument: $1 (modes: apply | auto | check | enable-check | disable-check | status)" ;;
  esac
done

if [ -n "$SRCDIR" ] && [ ! -d "$SRCDIR" ]; then die "source dir not found: $SRCDIR"; fi
if [ -z "$SRCDIR" ]; then
  case "$REPO" in
    *'{{'*)
      die "This copy of the helper is not configured with a source repository.
Download update-patcher.sh from the Releases page of a
PrismLauncherOfflinePatch repository - the release-page copy carries its
source already - or pass it once with --repo owner/name."
      ;;
  esac
  [ -n "$REPO" ] || die "no source repository given (use --repo owner/name)"
fi

OS="$(uname -s)"
if [ "$OS" != "Linux" ] && [ "$OS" != "Darwin" ]; then
  die "unsupported platform: $OS (this script covers Linux and macOS)"
fi

# -------------------------------------------------------------- helpers ----

add_log() {
  if [ ! -d "$STABLE" ]; then mkdir -p "$STABLE" 2>/dev/null || return 0; fi
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE" 2>/dev/null || true
}

compare_tags() {
  # numeric per-component compare of two Prism tags; prints -1, 0 or 1
  a_raw="$(printf '%s' "$1" | sed -e 's/^[vV]//' -e 's/[^0-9.].*$//' -e 's/\.$//')"
  b_raw="$(printf '%s' "$2" | sed -e 's/^[vV]//' -e 's/[^0-9.].*$//' -e 's/\.$//')"
  oldifs="$IFS"
  IFS='.'
  set -f
  set -- $a_raw; a1="${1:-0}"; a2="${2:-0}"; a3="${3:-0}"
  set -- $b_raw; b1="${1:-0}"; b2="${2:-0}"; b3="${3:-0}"
  set +f
  IFS="$oldifs"
  if [ "$a1" -lt "$b1" ] 2>/dev/null; then printf -- -1; return; fi
  if [ "$a1" -gt "$b1" ] 2>/dev/null; then printf '1'; return; fi
  if [ "$a2" -lt "$b2" ] 2>/dev/null; then printf -- -1; return; fi
  if [ "$a2" -gt "$b2" ] 2>/dev/null; then printf '1'; return; fi
  if [ "$a3" -lt "$b3" ] 2>/dev/null; then printf -- -1; return; fi
  if [ "$a3" -gt "$b3" ] 2>/dev/null; then printf '1'; return; fi
  printf '0'
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    openssl dgst -sha256 -r "$1" | cut -d' ' -f1
  fi
}

expected_sha() { # $1 = asset name; SUMFILE must be set
  # the 'sub' keeps checksums.txt files with Windows line endings readable
  awk -v n="$1" '{ sub(/\r$/, "") } $1 == "SHA256" && $3 == n { print $2; exit }' "$SUMFILE"
}

marker_field() { # $1 = field, $2 = marker path
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$2" 2>/dev/null | head -n 1
}

notify() {
  if [ "$OS" = "Linux" ] && command -v notify-send >/dev/null 2>&1; then
    notify-send "Prism Launcher (patched)" "$*" 2>/dev/null || true
  elif [ "$OS" = "Darwin" ] && command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$*\" with title \"Prism Launcher (patched)\"" 2>/dev/null || true
  fi
}

fetch() { # $1 = url, $2 = output file
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$2" "$1" || die "download failed: $1"
  else
    wget -qO "$2" "$1" || die "download failed: $1"
  fi
}

# ---- release info ----------------------------------------------------------
# sets TAG, ASSET_NAME, ASSET_URL. With --source-dir the "release" is a local
# directory (assets + checksums.txt + tag.txt): used by the kit's self-test
# and rigs; no network involved.

get_release() {
  if [ -n "$SRCDIR" ]; then
    [ -f "$SRCDIR/tag.txt" ] || die "tag.txt missing in $SRCDIR"
    TAG="$(tr -d ' \r\n' < "$SRCDIR/tag.txt")"
    if [ "$OS" = "Linux" ]; then ASSET_NAME="$ASSET_LINUX"; else ASSET_NAME="PrismLauncher-macOS-$TAG.dmg"; fi
    [ -f "$SRCDIR/$ASSET_NAME" ] || die "this test release has no $ASSET_NAME"
    ASSET_URL="$SRCDIR/$ASSET_NAME"
    return 0
  fi
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || \
    die "need curl or wget to reach GitHub"
  if command -v curl >/dev/null 2>&1; then
    JSON="$(curl -fsSL -H 'User-Agent: prism-patch-update-helper' \
      "https://api.github.com/repos/$REPO/releases/latest")" || die "could not reach the GitHub API"
  else
    JSON="$(wget -qO- -U 'prism-patch-update-helper' \
      "https://api.github.com/repos/$REPO/releases/latest")" || die "could not reach the GitHub API"
  fi
  TAG="$(printf '%s' "$JSON" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  [ -n "$TAG" ] || die "could not read the latest release tag (rate limit?)"
  if [ "$OS" = "Linux" ]; then ASSET_NAME="$ASSET_LINUX"; else ASSET_NAME="PrismLauncher-macOS-$TAG.dmg"; fi
  ASSET_URL="$(printf '%s' "$JSON" | grep -o '"browser_download_url"[^,]*' \
    | sed 's/.*"\(https[^"]*\)".*/\1/' \
    | while IFS= read -r u; do
        if [ "$(basename "$u")" = "$ASSET_NAME" ]; then printf '%s\n' "$u"; fi
      done | head -n 1)"
  [ -n "$ASSET_URL" ] || die "this release ($TAG) has no $ASSET_NAME - the copy may not build this platform"
}

# ---- Linux: locate, download, verify, swap ------------------------------------

find_linux_target() {
  if [ -n "$DIR" ]; then
    [ -f "$DIR/$ASSET_LINUX" ] || die "no $ASSET_LINUX in $DIR"
    TARGET="$DIR/$ASSET_LINUX"
    return 0
  fi
  # the recorded marker knows where it installed - the normal case after
  # the first manual run
  for d in "$HOME/Applications" "$HOME/.local/bin" "$HOME/bin" "$HOME/Desktop"; do
    if [ -f "$d/$ASSET_LINUX" ] && [ -f "$d/$MARKER" ]; then
      TARGET="$d/$ASSET_LINUX"
      return 0
    fi
  done
  if [ "$MODE" = "auto" ]; then
    die "cannot locate the patched AppImage (no --dir, no marker). Run 'bash update-patcher.sh apply' once first."
  fi
  info "Where is your patched AppImage? Common spots:"
  info "  $HOME/Applications/$ASSET_LINUX"
  printf 'path (file or folder, empty = %s): ' "$HOME/Applications/$ASSET_LINUX"
  read -r answer
  d="${answer:-$HOME/Applications/$ASSET_LINUX}"
  if [ -f "$d" ]; then TARGET="$d"; return 0; fi
  if [ -f "$d/$ASSET_LINUX" ]; then TARGET="$d/$ASSET_LINUX"; return 0; fi
  die "no AppImage found at $d"
}

install_linux() {
  TARGET_DIR="$(dirname "$TARGET")"
  TMPD="$(mktemp -d "$TARGET_DIR/.update-patcher.tmp-XXXXXX")" || die "could not create a temp dir next to the AppImage"
  if [ -n "$SRCDIR" ]; then
    SUMFILE="$SRCDIR/checksums.txt"
    cp "$SRCDIR/$ASSET_NAME" "$TMPD/$ASSET_NAME" || die "copy from the test release failed"
  else
    info "  downloading $ASSET_NAME + checksums.txt ..."
    fetch "$ASSET_URL" "$TMPD/$ASSET_NAME"
    fetch "https://github.com/$REPO/releases/download/$TAG/checksums.txt" "$TMPD/checksums.txt"
    SUMFILE="$TMPD/checksums.txt"
  fi
  EXPECTED="$(expected_sha "$ASSET_NAME")"
  [ -n "$EXPECTED" ] || die "checksums.txt has no entry for $ASSET_NAME"
  GOT="$(sha256_of "$TMPD/$ASSET_NAME")"
  if [ "$GOT" != "$EXPECTED" ]; then
    die "checksum mismatch for $ASSET_NAME - expected $EXPECTED, got $GOT. Nothing was changed."
  fi
  info "  checksum verified."
  if [ -f "$TARGET" ]; then
    BACKUP="$TARGET.bak-$(date '+%Y%m%d-%H%M%S')"
    mv "$TARGET" "$BACKUP" || die "could not move the current AppImage aside"
    info "  old file kept as $(basename "$BACKUP")"
  fi
  cp "$TMPD/$ASSET_NAME" "$TARGET" || die "could not place the new AppImage (the backup keeps the old one)"
  chmod 755 "$TARGET" || die "could not set the executable bit"
  GOT="$(sha256_of "$TARGET")"
  if [ "$GOT" != "$EXPECTED" ]; then die "the swapped file does not match the checksum - inspect $TARGET_DIR"; fi
  printf '{"tag":"%s","asset":"%s","sha256":"%s","repo":"%s","target":"%s","installed_at":"%s","helper":"kit-21"}\n' \
    "$TAG" "$ASSET_NAME" "$GOT" "$REPO" "$TARGET" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$TARGET_DIR/$MARKER" \
    || die "could not write the marker file"
  info "  done - the patched launcher is now $TAG. Menu entries and Steam links"
  info "  keep working: the file name never changed."
  add_log "updated to $TAG"
}

# ---- macOS: locate, mount, verify, swap ---------------------------------------

find_mac_target() {
  if [ -n "$APP" ]; then
    [ -d "$APP" ] || die "app bundle not found: $APP"
    MAC_APP="$APP"
    return 0
  fi
  for a in "/Applications/Prism Launcher.app" "$HOME/Applications/Prism Launcher.app"; do
    if [ -d "$a" ]; then MAC_APP="$a"; return 0; fi
  done
  if [ "$MODE" = "auto" ]; then
    die "cannot find Prism Launcher.app. Run 'bash update-patcher.sh apply' once (it remembers)."
  fi
  printf 'path of the installed app (empty = /Applications/Prism Launcher.app): '
  read -r answer
  a="${answer:-/Applications/Prism Launcher.app}"
  [ -d "$a" ] || die "no app bundle at $a"
  MAC_APP="$a"
}

install_macos() {
  APP_DIR="$(dirname "$MAC_APP")"
  TMPD="$(mktemp -d "${TMPDIR:-/tmp}/prism-patcher.XXXXXX")" || die "could not create a temp dir"
  if [ -n "$SRCDIR" ]; then
    DMG="$SRCDIR/$ASSET_NAME"
    SUMFILE="$SRCDIR/checksums.txt"
  else
    info "  downloading $ASSET_NAME + checksums.txt ..."
    fetch "$ASSET_URL" "$TMPD/$ASSET_NAME"
    fetch "https://github.com/$REPO/releases/download/$TAG/checksums.txt" "$TMPD/checksums.txt"
    DMG="$TMPD/$ASSET_NAME"
    SUMFILE="$TMPD/checksums.txt"
  fi
  EXPECTED="$(expected_sha "$ASSET_NAME")"
  [ -n "$EXPECTED" ] || die "checksums.txt has no entry for $ASSET_NAME"
  GOT="$(sha256_of "$DMG")"
  if [ "$GOT" != "$EXPECTED" ]; then
    die "checksum mismatch for $ASSET_NAME - expected $EXPECTED, got $GOT. Nothing was changed."
  fi
  info "  checksum verified."
  info "  mounting the DMG ..."
  MOUNT_OUT="$(hdiutil attach -nobrowse -readonly "$DMG")" || die "hdiutil could not mount the DMG"
  VOL="$(printf '%s\n' "$MOUNT_OUT" | awk -F'\t' '/\/Volumes\// {print $NF}' | tail -n 1)"
  if [ -z "$VOL" ]; then die "could not find the mounted volume"; fi
  SRC_APP="$(find "$VOL" -maxdepth 1 -type d -iname '*.app' | head -n 1)"
  if [ -z "$SRC_APP" ]; then
    hdiutil detach "$VOL" >/dev/null 2>&1 || true
    die "no .app inside the DMG"
  fi
  info "  found $(basename "$SRC_APP") - swapping into $APP_DIR ..."
  BACKUP="${MAC_APP%.app} (backup $(date '+%Y%m%d-%H%M%S')).app"
  mv "$MAC_APP" "$BACKUP" || { hdiutil detach "$VOL" >/dev/null 2>&1 || true; die "could not move the current app aside"; }
  if command -v ditto >/dev/null 2>&1; then
    ditto "$SRC_APP" "$MAC_APP" || { hdiutil detach "$VOL" >/dev/null 2>&1 || true; die "copy failed (the old app is safe at $BACKUP)"; }
  else
    cp -R "$SRC_APP" "$MAC_APP" || { hdiutil detach "$VOL" >/dev/null 2>&1 || true; die "copy failed (the old app is safe at $BACKUP)"; }
  fi
  NEWVER="$(defaults read "$MAC_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
  hdiutil detach "$VOL" >/dev/null 2>&1 || { sleep 2; hdiutil detach "$VOL" >/dev/null 2>&1 || warn "the DMG volume may still be mounted (eject it by hand)"; }
  if [ "$NEWVER" != "$TAG" ]; then
    die "the installed app reports version '$NEWVER', expected '$TAG' (the old app is safe at $BACKUP)"
  fi
  printf '{"tag":"%s","asset":"%s","sha256":"%s","repo":"%s","target":"%s","installed_at":"%s","helper":"kit-21"}\n' \
    "$TAG" "$ASSET_NAME" "$GOT" "$REPO" "$MAC_APP" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$APP_DIR/$MARKER" \
    || die "could not write the marker file"
  info "  old app kept as $(basename "$BACKUP")"
  info "  done - the patched launcher is now $TAG."
  info "  Files fetched by a script carry no quarantine mark, so Gatekeeper"
  info "  should not ask at the next launch."
  add_log "updated to $TAG"
}

# ---- background check (Linux systemd user timer; macOS: planned) ---------------

enable_check() {
  if [ "$OS" = "Darwin" ]; then
    info "The background check is not available on macOS yet (planned for the next"
    info "kit). The manual update works today: run this script without arguments."
    return 0
  fi
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found - the background check needs systemd"
  find_linux_target
  mkdir -p "$STABLE" || die "could not create $STABLE"
  cp "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" "$STABLE/update-patcher.sh" || die "could not copy the script"
  chmod 755 "$STABLE/update-patcher.sh" 2>/dev/null || true
  mkdir -p "$HOME/.config/systemd/user" || die "could not create the systemd user dir"
  EXTRA=""
  case "$REPO" in *'{{'*) ;; *) EXTRA="--repo $REPO" ;; esac
  TDIR="$(dirname "$TARGET")"
  cat > "$HOME/.config/systemd/user/prism-patch-update.service" <<EOF
[Unit]
Description=Prism Launcher patched-build update check
[Service]
Type=oneshot
ExecStart=$STABLE/update-patcher.sh auto --dir "$TDIR" $EXTRA
EOF
  cat > "$HOME/.config/systemd/user/prism-patch-update.timer" <<EOF
[Unit]
Description=Daily check for patched Prism Launcher updates
[Timer]
OnCalendar=daily
RandomizedDelaySec=45m
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload || die "systemctl --user daemon-reload failed (needs a desktop session)"
  systemctl --user enable --now prism-patch-update.timer || die "could not enable the timer"
  add_log "background check enabled (daily, randomized by 45m, catch-up when the machine was off)"
  info "Background check is on: a systemd user timer runs this script daily in"
  info "auto mode. On Linux the swap is safe even while the launcher runs - the"
  info "new version starts at the next launch. Everything it does lands in"
  info "  $LOGFILE"
  info "Remove it anytime: bash update-patcher.sh disable-check"
}

disable_check() {
  if [ "$OS" = "Darwin" ]; then
    info "Nothing is installed on macOS yet; nothing to remove."
    return 0
  fi
  if systemctl --user disable --now prism-patch-update.timer 2>/dev/null; then
    add_log "background check disabled"
    info "Background timer removed."
  else
    info "Background check is already off; nothing to do."
  fi
  rm -f "$HOME/.config/systemd/user/prism-patch-update.service" \
        "$HOME/.config/systemd/user/prism-patch-update.timer"
  systemctl --user daemon-reload 2>/dev/null || true
}

# ------------------------------------------------------------------ main ----

case "$MODE" in

  check)
    get_release
    if [ "$OS" = "Linux" ]; then
      find_linux_target
      MPATH="$(dirname "$TARGET")/$MARKER"
    else
      find_mac_target
      MPATH="$(dirname "$MAC_APP")/$MARKER"
    fi
    INSTALLED="$(marker_field tag "$MPATH" || true)"
    info "Latest patched release:  $TAG   (source: $REPO)"
    if [ -n "$INSTALLED" ]; then
      info "Installed here:          $INSTALLED (marker)"
    else
      info "Installed here:          unknown (no marker yet - run apply once)"
    fi
    if [ -n "$INSTALLED" ] && [ "$(compare_tags "$INSTALLED" "$TAG")" != "-1" ]; then
      info "This install is up to date."
    else
      info "An update is available - run: bash update-patcher.sh apply"
    fi
    ;;

  apply)
    get_release
    if [ "$OS" = "Linux" ]; then
      find_linux_target
      info "Latest patched release: $TAG (source: $REPO)"
      info "What changed: https://github.com/$REPO/releases/tag/$TAG"
      info ""
      info "Target: $TARGET"
      info "The swap is safe while the launcher runs (it executes from its own"
      info "mounted copy); the new version starts at the next launch."
      printf 'Update now? [Enter = yes] '
      read -r answer
      case "$answer" in [Nn]*) info "cancelled; nothing changed."; exit 0 ;; esac
      install_linux
    else
      find_mac_target
      if pgrep -f "Prism Launcher.app/Contents/MacOS" >/dev/null 2>&1; then
        info "  Prism Launcher is running. Close it, then press Enter (Ctrl+C to abort)."
        read -r dummy
      fi
      info "Latest patched release: $TAG (source: $REPO)"
      info "What changed: https://github.com/$REPO/releases/tag/$TAG"
      info ""
      info "Target: $MAC_APP"
      printf 'Replace the app with version %s? [Enter = yes] ' "$TAG"
      read -r answer
      case "$answer" in [Nn]*) info "cancelled; nothing changed."; exit 0 ;; esac
      install_macos
    fi
    ;;

  auto)
    # Non-interactive: silent when current, updates when it can, defers with
    # a notification when a swap must wait. Needs the marker from a first
    # manual run (or the --dir/--app flag).
    get_release
    if [ "$OS" = "Linux" ]; then
      find_linux_target
      MPATH="$(dirname "$TARGET")/$MARKER"
    else
      find_mac_target
      MPATH="$(dirname "$MAC_APP")/$MARKER"
    fi
    INSTALLED="$(marker_field tag "$MPATH" || true)"
    MSHA="$(marker_field sha256 "$MPATH" || true)"
    if [ -z "$INSTALLED" ]; then
      add_log "no marker at $MPATH - run apply once first"
      info "auto mode needs a first manual run to learn the install location."
      info "Run: bash update-patcher.sh apply"
      exit 0
    fi
    if [ "$OS" = "Linux" ]; then
      CURSHA="$(sha256_of "$TARGET")"
      INTACT="$([ "$CURSHA" = "$MSHA" ] && printf 'yes' || printf 'no')"
    else
      # on macOS the marker's sha256 is the DMG's, so integrity is judged by
      # the app's own reported version instead
      CURVER="$(defaults read "$MAC_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
      INTACT="$([ "$CURVER" = "$INSTALLED" ] && printf 'yes' || printf 'no')"
    fi
    if [ "$INTACT" != "yes" ]; then
      # the file changed underneath the marker: a manual replace, or the
      # official update ran. Never downgrade a NEWER official install to an
      # older patched build - that would break nothing on Linux/macOS (their
      # builds carry their own runtime), but it would confuse the version
      # bookkeeping; wait for the copy to publish the matching patched build.
      if [ "$OS" = "Darwin" ]; then
        NATIVE="$CURVER"
      else
        NATIVE="$(timeout 15 "$TARGET" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)*' | head -n 1 || true)"
      fi
      if [ -n "$NATIVE" ] && [ "$(compare_tags "$NATIVE" "$TAG")" = "1" ]; then
        add_log "official $NATIVE is newer than the newest patched build ($TAG); waiting"
        exit 0
      fi
      add_log "the target no longer matches the marker (installed $INSTALLED); re-applying $TAG"
    fi
    if [ "$INTACT" = "yes" ] && [ "$(compare_tags "$INSTALLED" "$TAG")" != "-1" ]; then
      exit 0   # current; the scheduled run ends here without a peep
    fi
    if [ "$OS" = "Darwin" ] && pgrep -f "Prism Launcher.app/Contents/MacOS" >/dev/null 2>&1; then
      notify "Update to $TAG is ready - close Prism, then run the update script"
      add_log "update $TAG deferred: the launcher was running"
      info "deferred - will try again on the next scheduled run."
      exit 0
    fi
    if [ "$OS" = "Linux" ]; then install_linux; else install_macos; fi
    notify "Prism Launcher (patched) updated to $TAG"
    ;;

  enable-check)  enable_check ;;
  disable-check) disable_check ;;

  status)
    info "Source repository:  $REPO"
    get_release
    if [ "$OS" = "Linux" ]; then
      find_linux_target
      MPATH="$(dirname "$TARGET")/$MARKER"
    else
      find_mac_target
      MPATH="$(dirname "$MAC_APP")/$MARKER"
    fi
    INSTALLED="$(marker_field tag "$MPATH" || true)"
    info "Latest release:     $TAG"
    if [ -n "$INSTALLED" ]; then info "Installed:          $INSTALLED (marker)"; else info "Installed:          unknown (no marker)"; fi
    if [ "$OS" = "Linux" ]; then
      ST="$(systemctl --user is-enabled prism-patch-update.timer 2>/dev/null || true)"
      info "Background timer:   ${ST:-not installed}"
    else
      info "Background timer:   planned (not yet on macOS)"
    fi
    info "Log:                $LOGFILE"
    ;;

  *)
    die "unknown mode '$MODE'. Use: apply | auto | check | enable-check | disable-check | status"
    ;;
esac
