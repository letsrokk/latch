#!/bin/zsh
set -euo pipefail

root="${0:A:h:h:h}"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/latch-release-validator.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

app="$test_root/LATCH.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/Helpers"
for executable in \
    "$app/Contents/MacOS/LATCH" \
    "$app/Contents/Library/Helpers/LATCHDaemon" \
    "$app/Contents/Library/Helpers/LATCHAgent" \
    "$app/Contents/Library/Helpers/LATCHProbe"; do
    touch "$executable"
    chmod +x "$executable"
done

cat > "$test_root/lipo" <<'EOF'
#!/bin/zsh
print 'x86_64 arm64'
EOF
cat > "$test_root/nm" <<'EOF'
#!/bin/zsh
exit 0
EOF
cat > "$test_root/codesign" <<'EOF'
#!/bin/zsh
if [[ "$1" == -dv ]]; then
    print -u2 'Authority=Developer ID Application: Example (TEAMID)'
    print -u2 'TeamIdentifier=TEAMID'
    print -u2 'flags=0x10000(runtime)'
    print -u2 "Timestamp=${LATCH_MOCK_TIMESTAMP:-none}"
fi
exit 0
EOF
chmod +x "$test_root"/{lipo,nm,codesign}

if LATCH_LIPO_COMMAND="$test_root/lipo" \
    LATCH_NM_COMMAND="$test_root/nm" \
    LATCH_CODESIGN_COMMAND="$test_root/codesign" \
    "$root/scripts/validate-release-app.sh" "$app" TEAMID 2> "$test_root/error.log"; then
    print -u2 'The release validator accepted a signature without a secure timestamp.'
    exit 1
fi
grep -Fq 'does not have a secure signing timestamp' "$test_root/error.log"

LATCH_MOCK_TIMESTAMP='Aug 24, 2026 at 12:00:00' \
LATCH_LIPO_COMMAND="$test_root/lipo" \
LATCH_NM_COMMAND="$test_root/nm" \
LATCH_CODESIGN_COMMAND="$test_root/codesign" \
    "$root/scripts/validate-release-app.sh" "$app" TEAMID >/dev/null

print 'release validator test passed'
