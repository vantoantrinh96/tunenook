#!/usr/bin/env bash
# Writes a one-item Sparkle appcast to stdout.
#
#   scripts/make-appcast.sh <version> <build> <zip-url> <release-url> <signature-attrs> <notes-file>
#
# <signature-attrs> is sign_update's output verbatim: sparkle:edSignature="..." length="..."
# The notes go in <description> as Markdown (Sparkle 2.10 documents sparkle:format="markdown").
set -euo pipefail

if [[ $# -ne 6 ]]; then
    sed -n '2,7p' "$0" >&2
    exit 2
fi

version="$1" build="$2" zip_url="$3" release_url="$4" signature_attrs="$5" notes_file="$6"

# Escape for XML text and attribute values.
xml_escape() {
    # sed, not ${var//pat/rep}: bash 5.2 patsub_replacement treats & in the replacement as the match.
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

notes="$(cat "$notes_file")"
# A CDATA section ends at the first ]]>, so split each one across two sections.
cdata_end=']]>' cdata_split=']]]]><![CDATA[>'
notes="${notes//"$cdata_end"/$cdata_split}"
pub_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>TuneNook</title>
    <item>
      <title>TuneNook $(xml_escape "$version")</title>
      <link>$(xml_escape "$release_url")</link>
      <pubDate>$pub_date</pubDate>
      <sparkle:version>$(xml_escape "$build")</sparkle:version>
      <sparkle:shortVersionString>$(xml_escape "$version")</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[$notes]]></description>
      <enclosure url="$(xml_escape "$zip_url")" $signature_attrs type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
