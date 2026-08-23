#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE

if (( $# != 1 )); then
    print -u2 "Usage: prepare-app-for-replacement.sh /path/to/LATCH"
    exit 64
fi

executable="$1"
wait_attempts="${LATCH_REPLACEMENT_WAIT_ATTEMPTS:-60}"
wait_interval="${LATCH_REPLACEMENT_WAIT_INTERVAL:-0.25}"

if [[ ! -x "$executable" ]]; then
    print -u2 "LATCH replacement preparation executable is unavailable: $executable"
    exit 66
fi
if [[ "$wait_attempts" != <-> ]] || (( wait_attempts < 1 )); then
    print -u2 "LATCH_REPLACEMENT_WAIT_ATTEMPTS must be a positive integer."
    exit 64
fi

preparation_directory="$(mktemp -d "${TMPDIR:-/tmp}/latch-replacement-preparation.XXXXXX")"
preparation_marker="$preparation_directory/ready"
preparation_pid=""

cleanup() {
    if [[ -n "$preparation_pid" ]] && kill -0 "$preparation_pid" 2>/dev/null; then
        kill -TERM "$preparation_pid" 2>/dev/null || true
        wait "$preparation_pid" 2>/dev/null || true
    fi
    rm -rf "$preparation_directory"
}
trap cleanup EXIT INT TERM

"$executable" "--prepare-for-app-replacement=$preparation_marker" &
preparation_pid=$!

for _ in {1..$wait_attempts}; do
    if [[ -f "$preparation_marker" ]]; then
        if kill -0 "$preparation_pid" 2>/dev/null; then
            kill -TERM "$preparation_pid" 2>/dev/null || true
        fi
        wait "$preparation_pid" 2>/dev/null || true
        preparation_pid=""
        exit 0
    fi
    if ! kill -0 "$preparation_pid" 2>/dev/null; then
        wait "$preparation_pid" 2>/dev/null || true
        preparation_pid=""
        print -u2 "LATCH exited before it could unregister its services. The existing app was left unchanged."
        exit 75
    fi
    sleep "$wait_interval"
done

print -u2 "LATCH timed out while unregistering its services. The existing app was left unchanged."
exit 75
