# LATCH Rebrand + Repository Reset Plan (Handoff)

## Goal

Rebrand the project at:

`/Users/rokk/Projects/github/utils/vacuum`

from **VACUUM** to **LATCH — LAN Automount, Tracking, Connection & Health**, then reinitialize repository history and push to:

`git@github.com:letsrokk/latch.git`

No existing VACUUM history should be preserved.

---

## Execution Plan

### 1) Baseline and path sanity

1. Confirm active path is `/Users/rokk/Projects/github/utils/vacuum`.
2. Verify repository exists and has pending changes.
3. Capture current status for resume context:
   - `git status --short`
   - `git status --short .superpowers/sdd/2026-08-23-xcode-project-migration/progress.md`  
   (revert this file if unexpectedly modified).

### 2) Restore and finish pending rebrand edits

1. Ensure these top-level renames are present:
   - `VACUUM.xcodeproj` → `LATCH.xcodeproj`
   - `Sources/VACUUMApp` → `Sources/LATCHApp`
   - `Sources/VACUUMDaemon` → `Sources/LATCHDaemon`
   - `Sources/VACUUMAgent` → `Sources/LATCHAgent`
   - `Sources/VACUUMProbe` → `Sources/LATCHProbe`
   - `Sources/VACUUMNative` → `Sources/LATCHNative`
   - `Sources/VACUUMShared` → `Sources/LATCHShared`
   - `Tests/VACUUMSharedTests` → `Tests/LATCHTests`
   - `readme/vacuum-overview.png` → `readme/latch-overview.png`
   - `Scripts/check-vacuum-*` → `Scripts/check-latch-*`
   - launch agents/daemons plist filenames to `latch`.
2. Validate/patch Xcode project references (`.pbxproj`, `.xcscheme`) for:
   - product names: `LATCH`, `LATCHDaemon`, `LATCHAgent`, `LATCHProbe`
   - shared/product/module/test target names: `LATCHShared`, `LATCHNative`, `LATCHTests`
   - scheme: `LATCH`
   - paths to `LATCH` source/test directories.
3. Replace identifiers and branding tokens:
   - bundle IDs:  
     - app `com.github.letsrokk.latch`  
     - daemon/agent/probe `com.github.letsrokk.latch.daemon|agent|probe`  
     - prefs `com.github.letsrokk.latch.shared`
   - config UTI `com.github.letsrokk.latch.configuration`
   - configuration extension `.latchconfig`
   - storage root `/Library/Application Support/LATCH`
   - public API/presentation types/events/errors/notifications: `LATCH*` instead of `VACUUM*`
   - native C names: `latch_*` instead of `vacuum_*`
   - team ID constant `LATCHTeamIdentifier`
   - scripts/envars/window IDs/notification IDs/files renamed consistently.
4. Ensure README uses the exact description verbatim:

   `LATCH (LAN Automount, Tracking, Connection & Health) keeps NFS volumes available on macOS without constant supervision. This native menu-bar app brings server discovery, mount management, health monitoring, and safe recovery into one focused control center for Macs that depend on NAS storage.`

5. Preserve historical docs:
   - keep `design-qa.md` and historical plans/specs intact.
   - update current system-test documentation and README branding references only.
6. Ensure docs/UI copy in About and relevant interface shows:
   - `LATCH` and `LAN Automount, Tracking, Connection & Health`
7. Generate `readme/latch-overview.png` from LATCH visual-preview build output.

### 3) Contract/style verification pass

1. Ensure no active source still uses VACUUM tokens where branding should be replaced:
   - search all active project files for: `VACUUM`, `vacuum`, `com.github.letsrokk.vacuum`
   - exclude historical-only docs if required by policy.
2. Verify scripts and tests updated:
   - `Scripts/` contract checks
   - build/test scripts
   - Makefile targets
3. Run checks:
   - `make check`
   - focused tests
   - full test suite
   - project contract tests/build scripts referenced by repo
4. Build app and verify packaging artifacts:
   - build `LATCH.app`
   - inspect bundle for identifiers, launchd plist names/paths, helper names/identifiers
   - verify code signing for app + helper processes.
5. Confirm no rebuilt LATCH process is left running.

### 4) Repo reset and push (only after verification passes)

1. Remove old git metadata (history wipe):
   - delete `.git` directory.
2. Reinitialize:
   - `git init -b main`
3. Stage clean verified tree:
   - `git add -A`
4. Commit:
   - `git commit -m "Initial LATCH codebase"`
5. Add remote:
   - `git remote add origin git@github.com:letsrokk/latch.git`
6. Push:
   - `git push -u origin main`
7. Verify remote reference:
   - compare local `git rev-parse HEAD` with `git ls-remote --heads origin main`.

### 5) User-facing migration note

Do not attempt to unregister/delete VACUUM instances.
Document that users must remove existing VACUUM services before enabling LATCH (clean break behavior).

---

## Handoff Notes for Next Session

- Working tree likely already has many rename changes staged/unstaged from prior pass.
- Major blocker in prior runs: command execution environment started in wrong directory and shell tool path issues.
- Keep this file as the canonical handoff so the next session can resume with exact execution order.

