#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
    print -u2 "Usage: $0 /path/to/LATCH.app /output/directory"
    exit 64
fi

source_app="$1"
output_directory="$2"
script_directory="${0:A:h}"
output_app="$output_directory/LATCH.app"

if [[ ! -d "$source_app" || "$source_app" != *.app ]]; then
    print -u2 "The source product must be an existing app bundle: $source_app"
    exit 66
fi

mkdir -p "$output_directory"
staging_directory="$(mktemp -d "$output_directory/.latch-app-stage.XXXXXX")"
trap 'rm -rf "$staging_directory"' EXIT
staged_app="$staging_directory/LATCH.app"

# Keep the Xcode product intact. The replacement helper consumes the staged
# copy, while ditto preserves the bundle's metadata and code signature.
ditto "$source_app" "$staged_app"

# The script test uses a minimal, unsigned bundle. Xcode products contain the
# executable below, so verify those products without ever signing or mutating
# either bundle.
if [[ -x "$staged_app/Contents/MacOS/LATCH" ]]; then
    codesign --verify --deep --strict --verbose=2 "$staged_app"
fi

if [[ -x "$output_app/Contents/MacOS/LATCH" ]]; then
    # The process check targets the destination executable being replaced. Do
    # not stop the source product, which lives under Xcode's derived data.
    /bin/zsh "$script_directory/stop-running-app.sh" "$output_app/Contents/MacOS/LATCH"
    if [[ "$(/usr/libexec/PlistBuddy -c 'Print :LATCHSupportsAtomicReplacementPreparation' "$output_app/Contents/Info.plist" 2>/dev/null || true)" == true ]]; then
        /bin/zsh "$script_directory/prepare-app-for-replacement.sh" "$output_app/Contents/MacOS/LATCH"
    fi
fi

/bin/zsh "$script_directory/atomic-replace-app.sh" "$staged_app" "$output_app"
print "$output_app"
