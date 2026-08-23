#!/bin/zsh
set -euo pipefail

test_root="$(mktemp -d "${TMPDIR:-/tmp}/latch-xcode-stage.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/product/LATCH.app" "$test_root/dist/LATCH.app"
print new > "$test_root/product/LATCH.app/version"
print old > "$test_root/dist/LATCH.app/version"

"$PWD/scripts/stage-xcode-app.sh" "$test_root/product/LATCH.app" "$test_root/dist"

[[ "$(<"$test_root/dist/LATCH.app/version")" == new ]]
[[ "$(<"$test_root/product/LATCH.app/version")" == new ]]
