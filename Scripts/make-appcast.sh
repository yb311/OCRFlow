#!/usr/bin/env bash
# Writes the Sparkle appcast for one release to stdout.
#
# Versions and the minimum macOS come from the built app itself, so the feed
# can never disagree with the bundle it is advertising.
#
# Usage:
#   Scripts/make-appcast.sh <OCRFlow.app> <archive> <archive URL> <EdDSA signature> <release notes HTML>
set -euo pipefail

APP="${1:?usage: make-appcast.sh <app> <archive> <url> <signature> <notes.html>}"
ARCHIVE="${2:?missing archive}"
URL="${3:?missing archive URL}"
SIGNATURE="${4:?missing EdDSA signature}"
NOTES="${5:?missing release notes HTML file}"

plist="${APP}/Contents/Info.plist"
short="$(plutil -extract CFBundleShortVersionString raw "${plist}")"
build="$(plutil -extract CFBundleVersion raw "${plist}")"
minimum="$(plutil -extract LSMinimumSystemVersion raw "${plist}")"
length="$(stat -f%z "${ARCHIVE}")"

# Text and attribute values XML-escaped: an archive URL with a query string
# carries `&`. (sed, not ${var//…}: bash 5.2 reads `&` in the replacement as
# the match.)
xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' -e "s/'/\\&apos;/g"
}
url_xml="$(xml_escape "${URL}")"
short_xml="$(xml_escape "${short}")"
build_xml="$(xml_escape "${build}")"
minimum_xml="$(xml_escape "${minimum}")"
signature_xml="$(xml_escape "${SIGNATURE}")"
# The notes go in CDATA as they are, but for `]]>`, which would end it: split
# there into two sections.
notes="$(sed -e 's/]]>/]]]]><![CDATA[>/g' "${NOTES}")"

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>OCRFlow</title>
        <link>${url_xml}</link>
        <description>OCRFlow 更新</description>
        <language>zh</language>
        <item>
            <title>${short_xml}</title>
            <pubDate>$(date -R)</pubDate>
            <sparkle:version>${build_xml}</sparkle:version>
            <sparkle:shortVersionString>${short_xml}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${minimum_xml}</sparkle:minimumSystemVersion>
            <description><![CDATA[
${notes}
]]></description>
            <enclosure url="${url_xml}"
                       length="${length}"
                       type="application/octet-stream"
                       sparkle:edSignature="${signature_xml}" />
        </item>
    </channel>
</rss>
XML
