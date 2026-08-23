#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
    print -u2 "Usage: $0 /path/to/LATCH.app/Contents/MacOS/LATCH"
    exit 64
fi

executable="$1"
process_ids=()
ps_command="${LATCH_PS_COMMAND:-ps}"
kill_command="${LATCH_KILL_COMMAND:-kill}"

while read -r process_id process_command; do
    if [[ "$process_command" == "$executable" ]]; then
        process_ids+=("$process_id")
    fi
done < <("$ps_command" -ax -o pid= -o comm=)

if (( ${#process_ids} == 0 )); then
    exit 0
fi

"$kill_command" -TERM "${process_ids[@]}"

for _ in {1..20}; do
    remaining=()
    for process_id in "${process_ids[@]}"; do
        if "$kill_command" -0 "$process_id" 2>/dev/null; then
            remaining+=("$process_id")
        fi
    done
    if (( ${#remaining} == 0 )); then
        exit 0
    fi
    sleep 0.25
done

print -u2 "LATCH is still running. Quit it, then run the build again."
exit 75
