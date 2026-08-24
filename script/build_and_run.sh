#!/bin/zsh
set -euo pipefail

mode="${1:-run}"
root_directory="${0:A:h:h}"
derived_data="$root_directory/.build/xcode-run-derived-data"
output_directory="$root_directory/.build/run"
source_app="$derived_data/Build/Products/Debug/LATCH.app"
app_bundle="$output_directory/LATCH.app"

case "$mode" in
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
    *)
        print -u2 "Usage: $0 [run|--debug|--logs|--telemetry|--verify]"
        exit 64
        ;;
esac

xcodebuild \
    -project "$root_directory/LATCH.xcodeproj" \
    -scheme LATCH \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    build

/bin/zsh "$root_directory/scripts/stage-xcode-app.sh" "$source_app" "$output_directory" >/dev/null

open_app() {
    /usr/bin/open -n "$app_bundle"
}

case "$mode" in
    run)
        open_app
        ;;
    --debug|debug)
        lldb -- "$app_bundle/Contents/MacOS/LATCH"
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact --predicate 'process == "LATCH"'
        ;;
    --telemetry|telemetry)
        open_app
        /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.github.letsrokk.latch"'
        ;;
    --verify|verify)
        open_app
        sleep 1
        pgrep -x LATCH >/dev/null
        ;;
esac
