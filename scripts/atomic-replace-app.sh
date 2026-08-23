#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
    print -u2 "Usage: $0 /staged/LATCH.app /output/LATCH.app"
    exit 64
fi

staged_app="$1"
output_app="$2"
script_directory="${0:A:h}"

if [[ "${staged_app:t}" != LATCH.app || "${output_app:t}" != LATCH.app ]]; then
    print -u2 "Atomic replacement is restricted to LATCH.app bundles."
    exit 64
fi
if [[ ! -d "$staged_app" ]]; then
    print -u2 "Staged app does not exist: $staged_app"
    exit 66
fi

mkdir -p "${output_app:h}"
if [[ ! -e "$output_app" ]]; then
    mv "$staged_app" "$output_app"
    exit 0
fi

swap_binary="$(mktemp "${TMPDIR:-/tmp}/latch-atomic-swap.XXXXXX")"
trap 'rm -f "$swap_binary"' EXIT
xcrun clang "$script_directory/atomic-swap.c" -o "$swap_binary"
"$swap_binary" "$staged_app" "$output_app"
rm -rf "$staged_app"
