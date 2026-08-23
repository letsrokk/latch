#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
    print -u2 "Usage: $0 /path/to/LATCH-AppIcon.png /path/to/LATCH.app"
    exit 64
fi

source_png="$1"
app="$2"
contents="$app/Contents"
info_plist="$contents/Info.plist"
resources="$contents/Resources"

if [[ ! -f "$source_png" ]]; then
    print -u2 "App icon source does not exist: $source_png"
    exit 66
fi
if [[ ! -f "$info_plist" ]]; then
    print -u2 "App Info.plist does not exist: $info_plist"
    exit 66
fi

width="$(sips -g pixelWidth "$source_png" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')"
height="$(sips -g pixelHeight "$source_png" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')"
if [[ "$width" != 1024 || "$height" != 1024 ]]; then
    print -u2 "App icon source must be 1024 by 1024 pixels."
    exit 65
fi

sips -s format icns "$source_png" --out "$resources/LATCH.icns" >/dev/null

declared_icon="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$info_plist" 2>/dev/null || true)"
if [[ "$declared_icon" != "LATCH.icns" ]]; then
    print -u2 "CFBundleIconFile must declare LATCH.icns."
    exit 65
fi
