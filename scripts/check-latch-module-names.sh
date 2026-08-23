#!/bin/zsh
set -euo pipefail

old_prefix="Guar""dian"
legacy_runtime_pattern='local''\.latch'
failures=""
for entry in Sources/${old_prefix}*(N) Tests/${old_prefix}*(N); do
    [[ -e "$entry" ]] && failures+="$entry\n"
done
pattern="(^|@testable )[[:space:]]*import ${old_prefix}(Shared|Native)|name: \"${old_prefix}(Shared|Native|Probe|Daemon|Agent|App)\"|/${old_prefix}(App|Daemon|Agent|Probe)\""
matches="$(rg -n "$pattern" Sources Tests scripts 2>/dev/null || true)"
[[ -n "$matches" ]] && failures+="$matches\n"
runtime_matches="$(rg -n "$legacy_runtime_pattern" Sources Tests Packaging scripts Makefile docs/system-test-checklist.md 2>/dev/null || true)"
[[ -n "$runtime_matches" ]] && failures+="$runtime_matches\n"

for module in LATCHShared LATCHNative LATCHProbe LATCHDaemon LATCHAgent LATCHApp; do
    if ! rg -q -- "${module}" Sources; then
        failures+="missing LATCH module name: ${module}\n"
    fi
done

if [[ -n "$failures" ]]; then
    print -u2 -- "Obsolete pre-LATCH module names remain:"
    print -u2 -r -- "$failures"
    exit 1
fi
