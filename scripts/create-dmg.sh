#!/usr/bin/env bash
# Build the Finder layout before compression, signing and notarization.
set -euo pipefail

if [[ $# -ne 2 || ! -d "$1/Contents" ]]; then
  echo "Usage: $0 <WesomeCloud.app> <output.dmg>" >&2
  exit 64
fi

scripts_dir="$(cd "$(dirname "$0")" && pwd)"
app_path="$(cd "$1" && pwd)"
mkdir -p "$(dirname "$2")"
dmg_path="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
work="$(mktemp -d "${TMPDIR:-/tmp}/wesome-dmg.XXXXXX")"
mounted=false
cleanup() {
  if [[ "$mounted" == true ]]; then
    if ! hdiutil detach "$work/volume" >/dev/null; then
      echo "Could not detach the test volume; retained $work for cleanup." >&2
      return
    fi
  fi
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/staging/.background" "$work/volume"
/usr/bin/ditto "$app_path" "$work/staging/WesomeCloud.app"
ln -s /Applications "$work/staging/Applications"
swift "$scripts_dir/dmg-background.swift" "$work/staging/.background/install.tiff"
hdiutil create -volname WesomeCloud -fs HFS+ -srcfolder "$work/staging" \
  -format UDRW "$work/layout.dmg"
hdiutil attach -readwrite -noverify -nobrowse -mountpoint "$work/volume" "$work/layout.dmg"
mounted=true

# Finder writes the window settings and icon positions into the volume's .DS_Store.
# This requires a logged-in macOS desktop and permission to automate Finder.
osascript - "$work/volume" <<'APPLESCRIPT'
on run argv
  set mountPath to item 1 of argv
  set diskFolder to POSIX file mountPath as alias
  tell application "Finder"
    set installWindow to make new Finder window to diskFolder
    tell installWindow
      set current view to icon view
      set toolbar visible to false
      set statusbar visible to false
      set bounds to {160, 160, 840, 608}
      set viewOptions to icon view options of installWindow
      tell viewOptions
        set arrangement to not arranged
        set icon size to 128
        set text size to 16
        set label position to bottom
        set background picture to POSIX file (mountPath & "/.background/install.tiff")
      end tell
    end tell
    set position of item "WesomeCloud.app" of diskFolder to {180, 207}
    set position of item "Applications" of diskFolder to {500, 207}
    set extension hidden of item "WesomeCloud.app" of diskFolder to true
    close installWindow
    open diskFolder
    update diskFolder without registering applications
    delay 2
    close container window of diskFolder
  end tell
end run
APPLESCRIPT

test -s "$work/volume/.DS_Store"
sync
hdiutil detach "$work/volume"
mounted=false
hdiutil convert "$work/layout.dmg" -format UDZO -o "$dmg_path" -ov
echo "Disk image: $dmg_path"
