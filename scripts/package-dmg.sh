#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
    print -u2 "Usage: $0 /path/to/LATCH.app /path/to/LATCH.dmg"
    exit 64
fi

app="$1"
dmg="$2"
tmp_root="${TMPDIR:-/tmp}"
staging_directory=""
temporary_dmg=""

if [[ ! -d "$app" || "$app" != *.app ]]; then
    print -u2 "The source must be an existing app bundle: $app"
    exit 66
fi

app_output_directory="${dmg:h}"
mkdir -p "$app_output_directory"

staging_directory="$(mktemp -d "${tmp_root%/}/latch-dmg-stage.XXXXXX")"
staged_app="$staging_directory/LATCH.app"

temporary_directory="$(mktemp -d "${app_output_directory%/}/.latch-dmg-output.XXXXXX")"
temporary_dmg="$temporary_directory/LATCH.dmg"

cleanup() {
    rm -rf "$staging_directory"
    rm -rf "$temporary_directory"
}
trap cleanup EXIT INT TERM

ditto "$app" "$staged_app"
ln -s /Applications "$staging_directory/Applications"

hdiutil create \
    -volname "LATCH" \
    -srcfolder "$staging_directory" \
    -format UDZO \
    "$temporary_dmg"

mv "$temporary_dmg" "$dmg"
