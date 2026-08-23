#!/bin/zsh
set -euo pipefail

step="${STEP:-}"
ack="${SYSTEM_TEST_ACK:-}"
run_id="${SYSTEM_TEST_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
root="$PWD"
run_dir="$root/.build/system-tests/$run_id"
manifest="$run_dir/manifest.env"
installed_app="/Applications/LATCH.app"

usage() {
    print -u2 "Usage: make system-test STEP=preflight|install|approval|replace|prepare-login|verify-login|restore SYSTEM_TEST_ACK=YES"
}

fail() { print -u2 "system-test: $1"; exit 65; }

[[ -n "$step" ]] || { usage; exit 64; }
[[ "$ack" == YES ]] || fail "SYSTEM_TEST_ACK=YES is required; this harness changes installed-system state."
mkdir -p "$run_dir"

write_manifest() {
    print -r -- "RUN_DIR=$run_dir" > "$manifest"
    print -r -- "EXPECTED_BUNDLE_VERSION=${EXPECTED_BUNDLE_VERSION:-}" >> "$manifest"
    print -r -- "BACKUP_DIR=${BACKUP_DIR:-}" >> "$manifest"
}

load_manifest() {
    [[ -f "$manifest" ]] || fail "No manifest exists for run $run_id; run STEP=preflight first."
    source "$manifest"
}

case "$step" in
preflight)
    [[ -d "$installed_app" ]] || fail "Install LATCH.app in /Applications before running preflight."
    [[ -n "${SIGNING_IDENTITY:-}" ]] || fail "SIGNING_IDENTITY is required."
    [[ -n "${TEAM_ID:-}" ]] || fail "TEAM_ID is required."
    security find-identity -v -p codesigning | grep -F "$SIGNING_IDENTITY" >/dev/null || fail "Signing identity was not found."
    backup_dir="$run_dir/backup"
    mkdir -p "$backup_dir"
    ditto "$installed_app" "$backup_dir/LATCH.app"
    if [[ -d "/Library/Application Support/LATCH" ]]; then
        ditto "/Library/Application Support/LATCH" "$backup_dir/LATCH-support"
    fi
    defaults export com.github.letsrokk.latch.shared "$backup_dir/com.github.letsrokk.latch.shared.plist" 2>/dev/null || true
    launchctl print system/com.github.letsrokk.latch.daemon > "$backup_dir/launchctl-daemon.txt" 2>&1 || true
    launchctl print "gui/$(id -u)/com.github.letsrokk.latch.agent" > "$backup_dir/launchctl-agent.txt" 2>&1 || true
    print -r -- "RUN_DIR=$run_dir" > "$manifest"
    print -r -- "BACKUP_DIR=$backup_dir" >> "$manifest"
    print -r -- "SIGNING_IDENTITY=$SIGNING_IDENTITY" >> "$manifest"
    print -r -- "TEAM_ID=$TEAM_ID" >> "$manifest"
    print "Preflight complete. Backup: $backup_dir"
    ;;
install)
    load_manifest
    make release APP="$run_dir/dist/LATCH.app" SIGNING_IDENTITY="$SIGNING_IDENTITY" TEAM_ID="$TEAM_ID"
    codesign --verify --deep --strict "$run_dir/dist/LATCH.app"
    /usr/bin/sudo "$root/scripts/atomic-replace-app.sh" "$run_dir/dist/LATCH.app" "$installed_app"
    open "$installed_app"
    print "Installed and launched the staged release app. Continue with approval in Settings."
    ;;
approval)
    load_manifest
    deadline=$(( $(date +%s) + 180 ))
    while (( $(date +%s) < deadline )); do
        daemon_state="$(launchctl print system/com.github.letsrokk.latch.daemon 2>&1 || true)"
        agent_state="$(launchctl print "gui/$(id -u)/com.github.letsrokk.latch.agent" 2>&1 || true)"
        if [[ "$daemon_state" != *"Could not find service"* && "$agent_state" != *"Could not find service"* ]]; then
            print "Monitoring services are registered. Verify approval in Login Items before continuing."
            exit 0
        fi
        sleep 5
    done
    fail "Approval window expired before both monitoring services were registered."
    ;;
replace)
    load_manifest
    make release APP="$run_dir/replacement/LATCH.app" SIGNING_IDENTITY="$SIGNING_IDENTITY" TEAM_ID="$TEAM_ID"
    /usr/bin/sudo "$root/scripts/atomic-replace-app.sh" "$run_dir/replacement/LATCH.app" "$installed_app"
    open "$installed_app"
    print "Replacement complete. Confirm both helpers reconnect without removing services."
    ;;
prepare-login)
    load_manifest
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$installed_app/Contents/Info.plist")"
    print -r -- "EXPECTED_BUNDLE_VERSION=$version" >> "$manifest"
    print "Recorded bundle version $version. Log out and back in, then run verify-login."
    ;;
verify-login)
    load_manifest
    deadline=$(( $(date +%s) + 60 ))
    while (( $(date +%s) < deadline )); do
        app_running=false
        pgrep -f "$installed_app/Contents/MacOS/LATCH" >/dev/null 2>&1 && app_running=true
        daemon_ok=false
        agent_ok=false
        launchctl print system/com.github.letsrokk.latch.daemon >/dev/null 2>&1 && daemon_ok=true
        launchctl print "gui/$(id -u)/com.github.letsrokk.latch.agent" >/dev/null 2>&1 && agent_ok=true
        if $app_running && $daemon_ok && $agent_ok; then
            print "Login verification passed for bundle version ${EXPECTED_BUNDLE_VERSION:-unknown}."
            exit 0
        fi
        sleep 5
    done
    fail "LATCH did not restore all expected login services within 60 seconds."
    ;;
restore)
    load_manifest
    [[ -d "$BACKUP_DIR/LATCH.app" ]] || fail "Backup app is missing; refusing to restore."
    print "Remove Monitoring Services through LATCH before restoring the backup."
    read -r "?Type RESTORE to continue: " confirmation
    [[ "$confirmation" == RESTORE ]] || fail "Restore cancelled."
    /usr/bin/sudo "$root/scripts/atomic-replace-app.sh" "$BACKUP_DIR/LATCH.app" "$installed_app"
    if [[ -d "$BACKUP_DIR/LATCH-support" ]]; then
        /usr/bin/sudo ditto "$BACKUP_DIR/LATCH-support" "/Library/Application Support/LATCH"
    fi
    if [[ -f "$BACKUP_DIR/com.github.letsrokk.latch.shared.plist" ]]; then
        defaults import com.github.letsrokk.latch.shared "$BACKUP_DIR/com.github.letsrokk.latch.shared.plist"
    fi
    print "Restore complete. Backup retained at $BACKUP_DIR. Background Task Management approval must be checked manually."
    ;;
*) usage; exit 64 ;;
esac
