#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
    print -u2 "Usage: $0 /path/to/LATCH.app keychain-profile"
    exit 64
fi

app="$1"
keychain_profile="$2"
if [[ ! -d "$app" || "$app" != *.app ]]; then
    print -u2 "The first argument must be an existing app bundle."
    exit 66
fi

"${0:A:h}/validate-release-app.sh" "$app"

temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
archive="$temporary_directory/LATCH.zip"

ditto -c -k --keepParent "$app" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$keychain_profile" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict --verbose=2 "$app"
