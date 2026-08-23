#!/bin/zsh
set -euo pipefail

test_root="$(mktemp -d "${TMPDIR:-/tmp}/latch-prepare-replacement.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

cat > "$test_root/succeeds" <<'EOF'
#!/bin/zsh
marker="${1#--prepare-for-app-replacement=}"
print 'ready' > "$marker"
EOF

cat > "$test_root/exits-early" <<'EOF'
#!/bin/zsh
exit 1
EOF

cat > "$test_root/hangs" <<'EOF'
#!/bin/zsh
while true; do sleep 1; done
EOF

chmod +x "$test_root/succeeds" "$test_root/exits-early" "$test_root/hangs"

"$PWD/scripts/prepare-app-for-replacement.sh" "$test_root/succeeds"

if LATCH_REPLACEMENT_WAIT_ATTEMPTS=2 LATCH_REPLACEMENT_WAIT_INTERVAL=0.01 \
    "$PWD/scripts/prepare-app-for-replacement.sh" "$test_root/exits-early" 2>/dev/null; then
    print -u2 "Expected an app that exits without a marker to fail preparation."
    exit 1
fi

if LATCH_REPLACEMENT_WAIT_ATTEMPTS=2 LATCH_REPLACEMENT_WAIT_INTERVAL=0.01 \
    "$PWD/scripts/prepare-app-for-replacement.sh" "$test_root/hangs" 2>/dev/null; then
    print -u2 "Expected a hung app to time out preparation."
    exit 1
fi
