#!/bin/zsh
set -euo pipefail

obsolete_pattern='guar''dian|nfsmount''guar''dian|guar''dian_'
legacy_runtime_pattern='local''\.latch'
legacy_service_prefix="local"".""latch"
active_paths=(Sources Tests Packaging scripts Makefile docs/system-test-checklist.md)
matches="$(rg -n -i "$obsolete_pattern" "${active_paths[@]}" 2>/dev/null || true)"
legacy_matches="$(rg -n "$legacy_runtime_pattern" "${active_paths[@]}" 2>/dev/null || true)"

readme_active="$(mktemp)"
trap 'rm -f "$readme_active"' EXIT
awk '
    BEGIN { in_cleanup = 0; in_code = 0 }
    /^## Manual cleanup of a pre-migration install$/ { in_cleanup = 1; print; next }
    in_cleanup && /^## / { in_cleanup = 0; in_code = 0 }
    in_cleanup && /^```/ { in_code = !in_code; next }
    in_cleanup && in_code { next }
    { print }
' README.md > "$readme_active"
readme_legacy_matches="$(rg -n "$legacy_runtime_pattern" "$readme_active" 2>/dev/null || true)"

if [[ -n "$legacy_matches" || -n "$readme_legacy_matches" ]]; then
    print -u2 -- "Legacy runtime identifiers remain in active sources or commands:"
    print -u2 -r -- "$legacy_matches"
    print -u2 -r -- "$readme_legacy_matches"
    exit 1
fi
if [[ -n "$matches" ]]; then
    print -u2 -- "Obsolete product branding remains:"
    print -u2 -r -- "$matches"
    exit 1
fi

for obsolete_plist in \
    "Packaging/LaunchAgents/${legacy_service_prefix}.agent.plist" \
    "Packaging/LaunchDaemons/${legacy_service_prefix}.daemon.plist"
do
    if [[ -e "$obsolete_plist" ]]; then
        print -u2 -- "Obsolete service plist remains: $obsolete_plist"
        exit 1
    fi
done

for required_plist in \
    Packaging/LaunchAgents/com.github.letsrokk.latch.agent.plist \
    Packaging/LaunchDaemons/com.github.letsrokk.latch.daemon.plist
do
    if [[ ! -f "$required_plist" ]]; then
        print -u2 -- "Required LATCH service plist is missing: $required_plist"
        exit 1
    fi
done

for identifier in \
    com.github.letsrokk.latch \
    com.github.letsrokk.latch.daemon \
    com.github.letsrokk.latch.agent
do
    if ! rg -F -q -- "$identifier" Packaging; then
        print -u2 -- "Packaging is missing required LATCH identifier: $identifier"
        exit 1
    fi
done
