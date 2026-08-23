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

stop_running_app() {
    local executable="$1"
    local process_ids=()
    local ps_command="${LATCH_PS_COMMAND:-ps}"
    local kill_command="${LATCH_KILL_COMMAND:-kill}"

    while read -r process_id process_command; do
        if [[ "$process_command" == "$executable" ]]; then
            process_ids+=("$process_id")
        fi
    done < <("$ps_command" -ax -o pid= -o comm=)

    if (( ${#process_ids[@]} == 0 )); then
        return 0
    fi

    "$kill_command" -TERM "${process_ids[@]}"

    for _ in {1..20}; do
        local remaining=()
        for process_id in "${process_ids[@]}"; do
            if "$kill_command" -0 "$process_id" 2>/dev/null; then
                remaining+=("$process_id")
            fi
        done
        if (( ${#remaining[@]} == 0 )); then
            return 0
        fi
        sleep 0.25
    done

    print -u2 "LATCH is still running. Quit it, then run the build again."
    return 75
}

prepare_for_replacement() {
    local executable="$1"
    local wait_attempts="${LATCH_REPLACEMENT_WAIT_ATTEMPTS:-60}"
    local wait_interval="${LATCH_REPLACEMENT_WAIT_INTERVAL:-0.25}"

    if [[ ! -x "$executable" ]]; then
        print -u2 "LATCH replacement preparation executable is unavailable: $executable"
        exit 66
    fi
    if [[ "$wait_attempts" != <-> ]] || (( wait_attempts < 1 )); then
        print -u2 "LATCH_REPLACEMENT_WAIT_ATTEMPTS must be a positive integer."
        exit 64
    fi

    (
        set -euo pipefail
        unsetopt BG_NICE

        local preparation_directory
        local preparation_marker
        local preparation_pid=""

        cleanup() {
            if [[ -n "$preparation_pid" ]] && kill -0 "$preparation_pid" 2>/dev/null; then
                kill -TERM "$preparation_pid" 2>/dev/null || true
                wait "$preparation_pid" 2>/dev/null || true
            fi
            rm -rf "$preparation_directory"
        }
        trap cleanup EXIT INT TERM

        preparation_directory="$(mktemp -d "${TMPDIR:-/tmp}/latch-replacement-preparation.XXXXXX")"
        preparation_marker="$preparation_directory/ready"

        "$executable" "--prepare-for-app-replacement=$preparation_marker" &
        preparation_pid=$!

        for _ in {1..$wait_attempts}; do
            if [[ -f "$preparation_marker" ]]; then
                if kill -0 "$preparation_pid" 2>/dev/null; then
                    kill -TERM "$preparation_pid" 2>/dev/null || true
                fi
                wait "$preparation_pid" 2>/dev/null || true
                preparation_pid=""
                return 0
            fi
            if ! kill -0 "$preparation_pid" 2>/dev/null; then
                wait "$preparation_pid" 2>/dev/null || true
                preparation_pid=""
                print -u2 "LATCH exited before it could unregister its services. The existing app was left unchanged."
                return 75
            fi
            sleep "$wait_interval"
        done

        print -u2 "LATCH timed out while unregistering its services. The existing app was left unchanged."
        return 75
    )
}

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
    stop_running_app "$output_app/Contents/MacOS/LATCH" || exit $?
    if [[ "$(/usr/libexec/PlistBuddy -c 'Print :LATCHSupportsAtomicReplacementPreparation' "$output_app/Contents/Info.plist" 2>/dev/null || true)" == true ]]; then
        prepare_for_replacement "$output_app/Contents/MacOS/LATCH" || exit $?
    fi
fi

/bin/zsh "$script_directory/atomic-replace-app.sh" "$staged_app" "$output_app"
print "$output_app"
