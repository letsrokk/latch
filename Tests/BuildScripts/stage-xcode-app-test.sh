#!/bin/zsh
set -euo pipefail

test_root="$(mktemp -d "${TMPDIR:-/tmp}/latch-xcode-stage.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

make_info_plist() {
    local plist_path="$1"
    local supports_preparation="${2:-false}"

    mkdir -p "${plist_path:h}"
    cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
EOF

    if [[ "$supports_preparation" == true ]]; then
        cat >> "$plist_path" <<EOF
    <key>LATCHSupportsAtomicReplacementPreparation</key><true/>
EOF
    fi

    cat >> "$plist_path" <<EOF
</dict>
</plist>
EOF
}

make_mock_app() {
    local app_path="$1"
    local version="$2"

    mkdir -p "$app_path/Contents"
    print "$version" > "$app_path/version"
}

touch_exec() {
    local executable_path="$1"
    mkdir -p "${executable_path:h}"
    cat > "$executable_path" <<'EOF'
#!/bin/zsh
exit 0
EOF
    chmod +x "$executable_path"
}

rm -f "$test_root/.tmp.log"
cat > "$test_root/no-process-ps" <<'EOF'
#!/bin/zsh
exit 0
EOF
chmod +x "$test_root/no-process-ps"

# The basic case should copy and stage a built app bundle while preserving source.
mkdir -p "$test_root/copy/product/LATCH.app" "$test_root/copy/dist/LATCH.app"
make_mock_app "$test_root/copy/product/LATCH.app" new
make_mock_app "$test_root/copy/dist/LATCH.app" old
"$PWD/scripts/stage-xcode-app.sh" "$test_root/copy/product/LATCH.app" "$test_root/copy/dist"
[[ "$(<"$test_root/copy/dist/LATCH.app/version")" == new ]]
[[ "$(<"$test_root/copy/product/LATCH.app/version")" == new ]]

# Existing LATCH process is terminated with TERM when replacing an active app.
mkdir -p "$test_root/process/product/LATCH.app" "$test_root/process/dist/LATCH.app/Contents/MacOS"
make_mock_app "$test_root/process/product/LATCH.app" new
make_mock_app "$test_root/process/dist/LATCH.app" old
make_info_plist "$test_root/process/dist/LATCH.app/Contents/Info.plist"
touch_exec "$test_root/process/dist/LATCH.app/Contents/MacOS/LATCH"

cat > "$test_root/ps" <<EOF
#!/bin/zsh
print '4242 $test_root/process/dist/LATCH.app/Contents/MacOS/LATCH'
EOF
cat > "$test_root/kill" <<'EOF'
#!/bin/zsh
if [[ "$1" == "-TERM" ]]; then
    print -r -- "$@" >> "$LATCH_KILL_LOG"
    exit 0
fi
if [[ "$1" == "-0" ]]; then
    exit 1
fi
exit 0
EOF
chmod +x "$test_root/ps" "$test_root/kill"

LATCH_PS_COMMAND="$test_root/ps" \
LATCH_KILL_COMMAND="$test_root/kill" \
LATCH_KILL_LOG="$test_root/kill.log" \
    "$PWD/scripts/stage-xcode-app.sh" "$test_root/process/product/LATCH.app" "$test_root/process/dist"
[[ "$(<"$test_root/process/dist/LATCH.app/version")" == new ]]
[[ -n "$(<"$test_root/kill.log")" ]]

# Successful replacement preparation should allow staging to continue.
mkdir -p "$test_root/prepare-success/product/LATCH.app" "$test_root/prepare-success/dist/LATCH.app/Contents/MacOS"
make_mock_app "$test_root/prepare-success/product/LATCH.app" new
make_mock_app "$test_root/prepare-success/dist/LATCH.app" old
make_info_plist "$test_root/prepare-success/dist/LATCH.app/Contents/Info.plist" true

cat > "$test_root/prepare-success/dist/LATCH.app/Contents/MacOS/LATCH" <<'EOF'
#!/bin/zsh
marker="${1#--prepare-for-app-replacement=}"
print ready > "$marker"
sleep 0.1
EOF
chmod +x "$test_root/prepare-success/dist/LATCH.app/Contents/MacOS/LATCH"
LATCH_PS_COMMAND="$test_root/no-process-ps" \
LATCH_REPLACEMENT_WAIT_ATTEMPTS=50 \
LATCH_REPLACEMENT_WAIT_INTERVAL=0.01 \
    "$PWD/scripts/stage-xcode-app.sh" "$test_root/prepare-success/product/LATCH.app" "$test_root/prepare-success/dist"
[[ "$(<"$test_root/prepare-success/dist/LATCH.app/version")" == new ]]

# Exited preparer process must keep the old app in place and exit with failure.
mkdir -p "$test_root/prepare-early/product/LATCH.app" "$test_root/prepare-early/dist/LATCH.app/Contents/MacOS"
make_mock_app "$test_root/prepare-early/product/LATCH.app" new
make_mock_app "$test_root/prepare-early/dist/LATCH.app" old
make_info_plist "$test_root/prepare-early/dist/LATCH.app/Contents/Info.plist" true
cat > "$test_root/prepare-early/dist/LATCH.app/Contents/MacOS/LATCH" <<'EOF'
#!/bin/zsh
exit 1
EOF
chmod +x "$test_root/prepare-early/dist/LATCH.app/Contents/MacOS/LATCH"

if LATCH_PS_COMMAND="$test_root/no-process-ps" \
    LATCH_REPLACEMENT_WAIT_ATTEMPTS=50 LATCH_REPLACEMENT_WAIT_INTERVAL=0.01 \
    "$PWD/scripts/stage-xcode-app.sh" "$test_root/prepare-early/product/LATCH.app" "$test_root/prepare-early/dist" \
    2> "$test_root/prepare-early/error.log"; then
    print -u2 "Expected replacement preparation to fail when the app exits early."
    exit 1
fi
rg -F -q "LATCH exited before it could unregister its services." "$test_root/prepare-early/error.log"
[[ "$(<"$test_root/prepare-early/dist/LATCH.app/version")" == old ]]
[[ -z "$(find "$test_root/prepare-early/dist" -maxdepth 1 -name '.latch-app-stage.*' -type d -print)" ]]

# If preparation times out, the existing app must remain untouched and temp staging
# artifacts must be cleaned up.
mkdir -p "$test_root/prepare-timeout/product/LATCH.app" "$test_root/prepare-timeout/dist/LATCH.app/Contents/MacOS"
make_mock_app "$test_root/prepare-timeout/product/LATCH.app" new
make_mock_app "$test_root/prepare-timeout/dist/LATCH.app" old
make_info_plist "$test_root/prepare-timeout/dist/LATCH.app/Contents/Info.plist" true
cat > "$test_root/prepare-timeout/dist/LATCH.app/Contents/MacOS/LATCH" <<'EOF'
#!/bin/zsh
while true; do
    sleep 1
done
EOF
chmod +x "$test_root/prepare-timeout/dist/LATCH.app/Contents/MacOS/LATCH"

if LATCH_PS_COMMAND="$test_root/no-process-ps" \
    LATCH_REPLACEMENT_WAIT_ATTEMPTS=2 LATCH_REPLACEMENT_WAIT_INTERVAL=0.01 \
    "$PWD/scripts/stage-xcode-app.sh" "$test_root/prepare-timeout/product/LATCH.app" "$test_root/prepare-timeout/dist" \
    2> "$test_root/prepare-timeout/error.log"; then
    print -u2 "Expected replacement preparation to timeout."
    exit 1
fi
rg -F -q "LATCH timed out while unregistering its services." "$test_root/prepare-timeout/error.log"
[[ "$(<"$test_root/prepare-timeout/dist/LATCH.app/version")" == old ]]
[[ -z "$(find "$test_root/prepare-timeout/dist" -maxdepth 1 -name '.latch-app-stage.*' -type d -print)" ]]
