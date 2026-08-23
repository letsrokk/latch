#!/bin/zsh
set -euo pipefail

app="${1:?Usage: $0 /path/to/LATCH.app}"
contents="$app/Contents"

[[ -x "$contents/MacOS/LATCH" ]]
[[ -x "$contents/Library/Helpers/LATCHDaemon" ]]
[[ -x "$contents/Library/Helpers/LATCHAgent" ]]
[[ -x "$contents/Library/Helpers/LATCHProbe" ]]
daemon_plist="$contents/Library/LaunchDaemons/com.github.letsrokk.latch.daemon.plist"
agent_plist="$contents/Library/LaunchAgents/com.github.letsrokk.latch.agent.plist"
[[ -f "$daemon_plist" ]]
[[ -f "$agent_plist" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$daemon_plist")" == com.github.letsrokk.latch.daemon ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$agent_plist")" == com.github.letsrokk.latch.agent ]]

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$contents/Info.plist")" == com.github.letsrokk.latch ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$contents/Info.plist")" == 15.0 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LATCHTeamIdentifier' "$contents/Info.plist")" == DR8RRE2NCU ]]
[[ -f "$contents/Resources/Assets.car" ]]

assert_signature() {
    local code_path="$1"
    local expected_identifier="$2"
    local signature
    local actual_identifier
    local actual_team_identifier

    signature="$(codesign -dv --verbose=4 "$code_path" 2>&1)"
    actual_identifier="$(print -r -- "$signature" | sed -n 's/^Identifier=//p')"
    actual_team_identifier="$(print -r -- "$signature" | sed -n 's/^TeamIdentifier=//p')"

    if [[ "$actual_identifier" != "$expected_identifier" ]]; then
        print -u2 "$code_path identifier: expected $expected_identifier, got $actual_identifier"
        return 1
    fi
    if [[ "$actual_team_identifier" != DR8RRE2NCU ]]; then
        print -u2 "$code_path team identifier: expected DR8RRE2NCU, got $actual_team_identifier"
        return 1
    fi
}

assert_signature "$app" com.github.letsrokk.latch
assert_signature "$contents/Library/Helpers/LATCHDaemon" com.github.letsrokk.latch.daemon
assert_signature "$contents/Library/Helpers/LATCHAgent" com.github.letsrokk.latch.agent
assert_signature "$contents/Library/Helpers/LATCHProbe" com.github.letsrokk.latch.probe

codesign --verify --deep --strict --verbose=2 "$app"
