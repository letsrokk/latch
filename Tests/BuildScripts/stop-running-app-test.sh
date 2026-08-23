#!/bin/zsh
set -euo pipefail

test_root="$(mktemp -d "${TMPDIR:-/tmp}/latch-stop-running.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

executable="$test_root/LATCH.app/Contents/MacOS/LATCH"
mkdir -p "${executable:h}"
touch "$executable"

cat > "$test_root/ps" <<EOF
#!/bin/zsh
print '4242 $executable'
EOF
cat > "$test_root/kill" <<'EOF'
#!/bin/zsh
if [[ "$1" == "-TERM" ]]; then
    print -r -- "$@" > "$LATCH_KILL_LOG"
    exit 0
fi
exit 1
EOF
chmod +x "$test_root/ps" "$test_root/kill"

LATCH_PS_COMMAND="$test_root/ps" \
LATCH_KILL_COMMAND="$test_root/kill" \
LATCH_KILL_LOG="$test_root/kill.log" \
    "$PWD/scripts/stop-running-app.sh" "$executable"

[[ "$(<"$test_root/kill.log")" == '-TERM 4242' ]]
