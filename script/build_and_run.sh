#!/bin/zsh
set -euo pipefail

mode="${1:-run}"
root_directory="${0:A:h:h}"
derived_data="${LATCH_RUN_DERIVED_DATA:-$root_directory/.build/xcode-run-derived-data}"
output_directory="${LATCH_RUN_OUTPUT_DIRECTORY:-$root_directory/.build/run}"
source_app="$derived_data/Build/Products/Debug/LATCH.app"
app_bundle="$output_directory/LATCH.app"
app_executable="$app_bundle/Contents/MacOS/LATCH"
ps_command="${LATCH_PS_COMMAND:-/bin/ps}"
kill_command="${LATCH_KILL_COMMAND:-/bin/kill}"
xcodebuild_command="${LATCH_XCODEBUILD_COMMAND:-xcodebuild}"
open_command="${LATCH_OPEN_COMMAND:-/usr/bin/open}"
sleep_command="${LATCH_SLEEP_COMMAND:-/bin/sleep}"
stop_attempts="${LATCH_RUN_STOP_ATTEMPTS:-50}"
stop_interval="${LATCH_RUN_STOP_INTERVAL:-0.1}"

case "$mode" in
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
    *)
        print -u2 "Usage: $0 [run|--debug|--logs|--telemetry|--verify]"
        exit 64
        ;;
esac

exact_process_ids() {
    "$ps_command" -ax -o pid= -o comm= | while read -r pid command; do
        [[ "$command" == "$app_executable" ]] && print -r -- "$pid"
    done
}

stop_staged_app() {
    local process_id
    for process_id in "${(@f)$(exact_process_ids)}"; do
        [[ -n "$process_id" ]] && "$kill_command" -TERM "$process_id" 2>/dev/null || true
    done
    local attempt
    for (( attempt = 1; attempt <= stop_attempts; attempt++ )); do
        [[ -z "$(exact_process_ids)" ]] && return 0
        "$sleep_command" "$stop_interval"
    done
    print -u2 "The staged LATCH executable did not exit after SIGTERM: $app_executable"
    return 75
}

stop_staged_app

"$xcodebuild_command" \
    -project "$root_directory/LATCH.xcodeproj" \
    -scheme LATCH \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    build

if [[ -n "${LATCH_STAGE_COMMAND:-}" ]]; then
    "$LATCH_STAGE_COMMAND" "$source_app" "$output_directory"
else
    /bin/zsh "$root_directory/scripts/stage-xcode-app.sh" "$source_app" "$output_directory" >/dev/null
fi

open_app() {
    "$open_command" -n "$app_bundle"
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
        "$sleep_command" 1
        if [[ -z "$(exact_process_ids)" ]]; then
            print -u2 "The staged LATCH executable did not launch: $app_executable"
            exit 75
        fi
        ;;
esac
