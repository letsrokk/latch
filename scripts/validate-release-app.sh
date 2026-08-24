#!/bin/zsh
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
    print -u2 "Usage: $0 /path/to/LATCH.app [expected-team-id]"
    exit 64
fi

app="$1"
expected_team_id="${2:-}"
codesign_command="${LATCH_CODESIGN_COMMAND:-/usr/bin/codesign}"
lipo_command="${LATCH_LIPO_COMMAND:-/usr/bin/lipo}"
nm_command="${LATCH_NM_COMMAND:-/usr/bin/nm}"
plistbuddy_command="${LATCH_PLISTBUDDY_COMMAND:-/usr/libexec/PlistBuddy}"
if [[ ! -d "$app" || "$app" != *.app ]]; then
    print -u2 "The first argument must be an existing app bundle."
    exit 66
fi

if [[ -z "$expected_team_id" ]]; then
    expected_team_id="$("$plistbuddy_command" -c 'Print :LATCHTeamIdentifier' "$app/Contents/Info.plist")"
fi

code_paths=(
    "$app"
    "$app/Contents/Library/Helpers/LATCHDaemon"
    "$app/Contents/Library/Helpers/LATCHAgent"
    "$app/Contents/Library/Helpers/LATCHProbe"
)
binary_paths=(
    "$app/Contents/MacOS/LATCH"
    "$app/Contents/Library/Helpers/LATCHDaemon"
    "$app/Contents/Library/Helpers/LATCHAgent"
    "$app/Contents/Library/Helpers/LATCHProbe"
)

for binary in "${binary_paths[@]}"; do
    [[ -x "$binary" ]] || { print -u2 "Missing executable: $binary"; exit 66; }
    architectures="$("$lipo_command" -archs "$binary")"
    [[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] || {
        print -u2 "$binary must contain arm64 and x86_64; found: $architectures"
        exit 65
    }
    symbols="$("$nm_command" -a "$binary" 2>/dev/null || true)"
    if /usr/bin/grep -q '__llvm_profile' <<< "$symbols"; then
        print -u2 "$binary contains LLVM coverage instrumentation."
        exit 65
    fi
done

for code_path in "${code_paths[@]}"; do
    if ! signature="$("$codesign_command" -dv --verbose=4 "$code_path" 2>&1)"; then
        print -u2 "$code_path is not signed."
        exit 65
    fi
    /usr/bin/grep -Fq 'Authority=Developer ID Application:' <<< "$signature" || {
        print -u2 "$code_path is not signed with Developer ID Application."
        exit 65
    }
    /usr/bin/grep -Fq "TeamIdentifier=$expected_team_id" <<< "$signature" || {
        print -u2 "$code_path is not signed by team $expected_team_id."
        exit 65
    }
    /usr/bin/grep -Eq '^flags=.*\(runtime\)' <<< "$signature" || {
        print -u2 "$code_path does not enable the hardened runtime."
        exit 65
    }
    /usr/bin/grep -Eq '^Timestamp=.+$' <<< "$signature" && ! /usr/bin/grep -Fq 'Timestamp=none' <<< "$signature" || {
        print -u2 "$code_path does not have a secure signing timestamp."
        exit 65
    }

    entitlements="$("$codesign_command" -d --entitlements :- "$code_path" 2>/dev/null || true)"
    task_allow="$(/usr/bin/grep -A1 -F '<key>com.apple.security.get-task-allow</key>' <<< "$entitlements" || true)"
    if /usr/bin/grep -Fq '<true/>' <<< "$task_allow"; then
        print -u2 "$code_path enables get-task-allow."
        exit 65
    fi
done

"$codesign_command" --verify --deep --strict --verbose=2 "$app"
print "release app validation passed"
