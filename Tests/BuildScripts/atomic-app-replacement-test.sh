#!/bin/zsh
set -euo pipefail

test_root="$(mktemp -d "${TMPDIR:-/tmp}/latch-atomic-replacement.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/staged/LATCH.app" "$test_root/output/LATCH.app"
print -r -- new > "$test_root/staged/LATCH.app/version"
print -r -- old > "$test_root/output/LATCH.app/version"

"$PWD/scripts/atomic-replace-app.sh" \
    "$test_root/staged/LATCH.app" \
    "$test_root/output/LATCH.app"

[[ "$(<"$test_root/output/LATCH.app/version")" == new ]]
[[ ! -e "$test_root/staged/LATCH.app" ]]
