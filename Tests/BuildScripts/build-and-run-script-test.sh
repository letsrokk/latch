#!/bin/zsh
set -euo pipefail

root="${0:A:h:h:h}"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/latch-run-script.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

output="$test_root/run"
exact_executable="$output/LATCH.app/Contents/MacOS/LATCH"
state="$test_root/state"
print running > "$state"

cat > "$test_root/ps" <<EOF
#!/bin/zsh
print '9000 /Applications/LATCH.app/Contents/MacOS/LATCH'
if [[ "\$(cat "$state")" != stopped ]]; then
    print '9001 $exact_executable'
fi
EOF
cat > "$test_root/kill" <<EOF
#!/bin/zsh
[[ "\$(cat "$state")" == running ]] && print stopped > "$state"
print -r -- "\$@" >> "$test_root/kill.log"
EOF
cat > "$test_root/xcodebuild" <<EOF
#!/bin/zsh
[[ "\$(cat "$state")" == stopped ]]
print built >> "$test_root/order.log"
EOF
cat > "$test_root/stage" <<EOF
#!/bin/zsh
mkdir -p "$output/LATCH.app/Contents/MacOS"
touch "$exact_executable"
chmod +x "$exact_executable"
print staged >> "$test_root/order.log"
EOF
cat > "$test_root/open" <<EOF
#!/bin/zsh
print running > "$state"
print opened >> "$test_root/order.log"
EOF
cat > "$test_root/sleep" <<'EOF'
#!/bin/zsh
exit 0
EOF
chmod +x "$test_root"/{ps,kill,xcodebuild,stage,open,sleep}

LATCH_RUN_OUTPUT_DIRECTORY="$output" \
LATCH_RUN_DERIVED_DATA="$test_root/derived" \
LATCH_PS_COMMAND="$test_root/ps" \
LATCH_KILL_COMMAND="$test_root/kill" \
LATCH_XCODEBUILD_COMMAND="$test_root/xcodebuild" \
LATCH_STAGE_COMMAND="$test_root/stage" \
LATCH_OPEN_COMMAND="$test_root/open" \
LATCH_SLEEP_COMMAND="$test_root/sleep" \
    "$root/script/build_and_run.sh" --verify

grep -Fq -- '-TERM 9001' "$test_root/kill.log"
[[ "$(<"$test_root/order.log")" == $'built\nstaged\nopened' ]]

# A staged executable that ignores SIGTERM must stop the workflow before the build.
print stuck > "$state"
: > "$test_root/order.log"
if LATCH_RUN_OUTPUT_DIRECTORY="$output" \
    LATCH_RUN_DERIVED_DATA="$test_root/derived" \
    LATCH_PS_COMMAND="$test_root/ps" \
    LATCH_KILL_COMMAND="$test_root/kill" \
    LATCH_XCODEBUILD_COMMAND="$test_root/xcodebuild" \
    LATCH_STAGE_COMMAND="$test_root/stage" \
    LATCH_OPEN_COMMAND="$test_root/open" \
    LATCH_SLEEP_COMMAND="$test_root/sleep" \
    LATCH_RUN_STOP_ATTEMPTS=2 \
    "$root/script/build_and_run.sh" --verify 2> "$test_root/stop-error.log"; then
    print -u2 'A stuck staged executable did not block the build.'
    exit 1
fi
grep -Fq 'did not exit after SIGTERM' "$test_root/stop-error.log"
[[ ! -s "$test_root/order.log" ]]

# An unrelated process with the same name must not satisfy verification.
print stopped > "$state"
if LATCH_RUN_OUTPUT_DIRECTORY="$output" \
    LATCH_RUN_DERIVED_DATA="$test_root/derived" \
    LATCH_PS_COMMAND="$test_root/ps" \
    LATCH_KILL_COMMAND="$test_root/kill" \
    LATCH_XCODEBUILD_COMMAND="$test_root/xcodebuild" \
    LATCH_STAGE_COMMAND="$test_root/stage" \
    LATCH_OPEN_COMMAND="$test_root/sleep" \
    LATCH_SLEEP_COMMAND="$test_root/sleep" \
    "$root/script/build_and_run.sh" --verify 2> "$test_root/error.log"; then
    print -u2 'An unrelated LATCH process satisfied exact verification.'
    exit 1
fi
grep -Fq 'staged LATCH executable did not launch' "$test_root/error.log"

print 'build and run script test passed'
