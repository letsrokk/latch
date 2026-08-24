#!/bin/zsh
set -euo pipefail

root="${0:A:h:h:h}"
makefile="$root/Makefile"
project="$root/LATCH.xcodeproj/project.pbxproj"
notarize="$root/scripts/notarize-app.sh"
validator="$root/scripts/validate-release-app.sh"

grep -Fq -- "-destination 'generic/platform=macOS'" "$makefile"
grep -Fq -- 'CLANG_ENABLE_CODE_COVERAGE = NO;' "$project"
grep -Fq -- 'CLANG_COVERAGE_MAPPING = NO;' "$project"
grep -Fq -- 'ENABLE_CODE_COVERAGE = NO;' "$project"
grep -Fq -- './scripts/validate-release-app.sh "$(APP)"' "$makefile"
grep -Fq -- 'validate-release-app.sh' "$notarize"
[[ -x "$validator" ]]

print 'release workflow contract test passed'
