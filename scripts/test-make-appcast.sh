#!/usr/bin/env bash
# Tests scripts/make-appcast.sh: well-formed XML, Sparkle fields, and a notes round trip.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

notes='Fixes <b> & "quotes" ]]> done'
printf '%s' "$notes" > "$tmp/notes"

rel_url='https://example.com/rel?a=1&b=<x>"q"'
"$here/make-appcast.sh" 1.2.3 42 https://example.com/T.zip "$rel_url" \
    'sparkle:edSignature="abc" length="10"' "$tmp/notes" > "$tmp/appcast.xml"

fail() { echo "FAIL: $1" >&2; exit 1; }
xp() { xmllint --xpath "$1" "$tmp/appcast.xml"; }

xmllint --noout "$tmp/appcast.xml" || fail "appcast.xml is not well-formed"

[[ "$(xp 'string(//*[local-name()="version"])')" == "42" ]] || fail "sparkle:version"
[[ "$(xp 'string(//*[local-name()="shortVersionString"])')" == "1.2.3" ]] || fail "sparkle:shortVersionString"
[[ "$(xp 'string(//*[local-name()="minimumSystemVersion"])')" == "14.0" ]] || fail "sparkle:minimumSystemVersion"
[[ "$(xp 'string(//enclosure/@url)')" == "https://example.com/T.zip" ]] || fail "enclosure url"
[[ "$(xp 'string(//enclosure/@*[local-name()="edSignature"])')" == "abc" ]] || fail "edSignature"
[[ "$(xp 'string(//enclosure/@length)')" == "10" ]] || fail "enclosure length"
[[ "$(xp 'string(//item/title)')" == "TuneNook 1.2.3" ]] || fail "title"
[[ "$(xp 'string(//item/link)')" == "$rel_url" ]] || fail "link"
grep -qF '<link>https://example.com/rel?a=1&amp;b=&lt;x&gt;&quot;q&quot;</link>' "$tmp/appcast.xml" \
    || fail "xml_escape output: $(grep '<link>' "$tmp/appcast.xml")"

desc="$(xp 'string(//item/description)')"
[[ "$desc" == "$notes" ]] || fail "description did not round-trip: $desc"
[[ "$desc" == *']]>'* ]] || fail "description lost ]]>"

echo "PASS: make-appcast"
