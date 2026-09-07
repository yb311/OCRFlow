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

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>OCRFlow</title>
        <link>${URL}</link>
        <description>OCRFlow 更新</description>
        <language>zh</language>
        <item>
            <title>${short}</title>
            <pubDate>$(date -R)</pubDate>
            <sparkle:version>${build}</sparkle:version>
            <sparkle:shortVersionString>${short}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${minimum}</sparkle:minimumSystemVersion>
            <description><![CDATA[
$(cat "${NOTES}")
]]></description>
            <enclosure url="${URL}"
                       length="${length}"
                       type="application/octet-stream"
                       sparkle:edSignature="${SIGNATURE}" />
        </item>
    </channel>
</rss>
XML
