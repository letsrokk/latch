#!/bin/zsh
set -euo pipefail

test_root="$(mktemp -d "${TMPDIR:-/tmp}/latch-dmg-script-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

package_script="$PWD/scripts/package-dmg.sh"

make_mock_app() {
    local app_path="$1"
    mkdir -p "$app_path/Contents"
    print "mock" > "$app_path/version"
}

mount_and_assert_image() {
    local image_path="$1"
    local mountpoint="$2"
    mkdir -p "$mountpoint"

    hdiutil attach -readonly -nobrowse -mountpoint "$mountpoint" "$image_path"

    [[ -d "$mountpoint/LATCH.app" ]]
    [[ -L "$mountpoint/Applications" ]]

    hdiutil detach "$mountpoint"
}

mkdir -p "$test_root/input" "$test_root/output" "$test_root/tmp"
make_mock_app "$test_root/input/LATCH.app"

TMPDIR="$test_root/tmp" "$package_script" "$test_root/input/LATCH.app" "$test_root/output/LATCH.dmg"

mount_and_assert_image "$test_root/output/LATCH.dmg" "$test_root/mount"

[[ -z "$(find "$test_root/tmp" -maxdepth 1 -name '.latch-dmg-stage.*' -type d -print)" ]]
[[ -z "$(find "$test_root/output" -maxdepth 1 -name '.latch-dmg-output.*' -type d -print)" ]]

existing_dmg="$test_root/output-existing/LATCH.dmg"
mkdir -p "$test_root/output-existing"
print "existing artifact" > "$existing_dmg"

if "$package_script" "$test_root/missing/LATCH.app" "$existing_dmg" 2> "$test_root/missing-error.log"; then
    print -u2 "Expected missing app input to fail."
    exit 1
fi

[[ "$(<"$existing_dmg")" == "existing artifact" ]]

[[ -z "$(find "$test_root/tmp" -maxdepth 1 -name '.latch-dmg-stage.*' -type d -print)" ]]
