#!/usr/bin/env bash
# Packs TuneNook.app into a compressed, read-only disk image with an Applications shortcut,
# so people can drag the app across to install it.
#
#   scripts/make-dmg.sh <path/to/TuneNook.app> <output.dmg>
set -euo pipefail

app=${1:?usage: make-dmg.sh <TuneNook.app> <output.dmg>}
out=${2:?usage: make-dmg.sh <TuneNook.app> <output.dmg>}

[ -d "$app" ] || { echo "No app at $app" >&2; exit 1; }

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

ditto "$app" "$staging/$(basename "$app")"
ln -s /Applications "$staging/Applications"

rm -f "$out"
hdiutil create -volname "TuneNook" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$out" >/dev/null
hdiutil verify "$out" >/dev/null
echo "$out"
