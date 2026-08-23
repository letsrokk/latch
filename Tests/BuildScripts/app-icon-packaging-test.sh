#!/bin/zsh
set -euo pipefail

test_root="$(mktemp -d "${TMPDIR:-/tmp}/latch-app-icon.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

app="$test_root/LATCH.app"
mkdir -p "$app/Contents/Resources"
cp "$PWD/Packaging/App-Info.plist" "$app/Contents/Info.plist"

/bin/zsh "$PWD/scripts/package-app-icon.sh" \
    "$PWD/Assets/LATCH-AppIcon.png" \
    "$app"

icon_file="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app/Contents/Info.plist")"
[[ "$icon_file" == "LATCH.icns" ]]
[[ -s "$app/Contents/Resources/$icon_file" ]]

expanded_iconset="$test_root/expanded.iconset"
iconutil --convert iconset --output "$expanded_iconset" "$app/Contents/Resources/$icon_file"
largest_representation="$expanded_iconset/icon_512x512@2x.png"
[[ -s "$largest_representation" ]]
[[ "$(sips -g pixelWidth "$largest_representation" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')" == 1024 ]]
[[ "$(sips -g pixelHeight "$largest_representation" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')" == 1024 ]]
