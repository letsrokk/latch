# Production Readiness Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve the latest macOS review findings and prove the resulting app and release pipeline are production-ready.

**Architecture:** Preserve the existing Xcode targets and extract only deterministic lifecycle, process, and application-control policies into `LATCHShared`. The daemon remains authoritative for operation admission and terminal results; the app reconnects to that state through XPC rather than imposing a local deadline.

**Tech Stack:** Swift 6, SwiftUI, AppKit, NSXPCConnection, Swift Testing, Xcode build scripts, codesign, and notarytool.

**Spec:** `docs/superpowers/specs/2026-08-24-production-readiness-remediation-design.md`

## Global Constraints

- Keep the deployment target at macOS 15.0 and preserve Swift 6 strict concurrency.
- Preserve the non-sandboxed privileged-daemon architecture and existing client-authentication checks.
- Never publish `cancelled` when cancellation leaves a mount in a failed-closed recovery state.
- Never accept two simultaneous manual operations for one mount.
- Never label a non-universal, coverage-instrumented, development-signed artifact as a production release.
- Use test-first changes for production behavior and retain all unrelated user work.

---

### Task 1: Authoritative operation lifecycle

**Files:**
- Create: `Sources/LATCHShared/OperationLifecycle.swift`
- Create: `Tests/LATCHTests/OperationLifecycleTests.swift`
- Modify: `Sources/LATCHShared/XPCProtocol.swift`
- Modify: `Sources/LATCHDaemon/DaemonController.swift`
- Modify: `Tests/LATCHTests/XPCTests.swift`

**Interfaces:**
- Produces: terminal-state classification, conflict admission, retention policy, `LATCHRequest.getOperations`, and `LATCHResponse.operationSnapshots([OperationSnapshot])`.
- Preserves: existing operation receipts and per-operation lookup.

- [x] Write failing tests for same-mount conflict rejection, different-mount admission, explicit terminal detection, failed-result precedence over cancellation, cancellation without failure, idempotent terminal cancellation, and pruning terminal snapshots without pruning active cancellation requests.
- [x] Run the focused tests and confirm failures identify the missing lifecycle contract.
- [x] Implement the lifecycle policy and XPC cases with the smallest public surface required by daemon and app.
- [x] Integrate daemon admission, remove generation invalidation from cancellation, record recovery results after cancellation, and evaluate failure before cancellation when publishing terminal state.
- [x] Run focused lifecycle, recovery, and XPC tests until green.

### Task 2: Reconnectable app monitoring and active managed-mount UI

**Files:**
- Modify: `Sources/LATCHApp/AppModel.swift`
- Modify: `Sources/LATCHApp/AppModel+Mounts.swift`
- Modify: `Sources/LATCHApp/AppModel+Services.swift`
- Modify: `Sources/LATCHApp/SettingsViews.swift`
- Modify: `Sources/LATCHApp/SettingsViews+OverviewAndMounts.swift`
- Modify: `Sources/LATCHApp/SettingsViews+SharedComponents.swift`
- Modify: `Tests/LATCHTests/UIContractTests.swift`

**Interfaces:**
- Consumes: operation-list XPC contract and terminal-state classification from Task 1.
- Produces: one monitor task per active operation, bounded transport retry, and active-operation presentation for every mount action surface.

- [x] Write failing tests for unlimited terminal polling policy, bounded retry delay, operation reconciliation, and managed-action enablement/cancellation state.
- [x] Confirm the focused UI contract tests fail for the existing fixed 120-attempt deadline and missing managed-mount state.
- [x] Replace the fixed deadline with reconciled daemon snapshots and lifecycle-owned monitor tasks.
- [x] Pass operation snapshots and cancellation actions into `ManagedMountsScreen`; disable conflicting actions, edits, and removal while active.
- [x] Run focused UI and XPC tests until green.

### Task 3: Cancellation-aware process and application-control seams

**Files:**
- Create: `Sources/LATCHShared/BoundedProcessRunner.swift`
- Create: `Sources/LATCHShared/ApplicationTerminationPolicy.swift`
- Create: `Tests/LATCHTests/BoundedProcessRunnerTests.swift`
- Create: `Tests/LATCHTests/ApplicationTerminationPolicyTests.swift`
- Modify: `Sources/LATCHAgent/main.swift`
- Modify: `Sources/LATCHDaemon/SystemOperations.swift`
- Modify: `Sources/LATCHShared/EditorPresentation.swift`
- Modify: `Tests/LATCHTests/UIContractTests.swift`

**Interfaces:**
- Produces: `BoundedProcessRunner.run(executable:arguments:environment:timeout:)`, cancellation-aware `ResponseDeadline`, and pure application URL/restart decisions.
- Preserves: existing daemon and agent error messages and command allowlists.

- [x] Write failing tests for stdout/stderr capture, large concurrent output, environment propagation, timeout termination, parent-task cancellation, equivalent application URLs, force-quit selection, and restart verification.
- [x] Confirm each focused test fails for the missing seam or current cancellation behavior.
- [x] Implement the shared runner and policies, then replace `FixedProcess` and `DockerCommandRunner` internals without broadening command authority.
- [x] Make `ResponseDeadline` resume and invoke cancellation cleanup when its parent task is cancelled.
- [x] Run focused runner, policy, timeout, recovery, and agent-command contract tests until green.

### Task 4: Native macOS settings and commands

**Files:**
- Modify: `Sources/LATCHApp/LATCHApp.swift`
- Modify: `Sources/LATCHApp/SettingsViews.swift`
- Modify: `Sources/LATCHApp/SettingsViews+Monitoring.swift`
- Modify: `Tests/LATCHTests/UIContractTests.swift`

**Interfaces:**
- Produces: a dedicated `Settings` scene, a reusable preferences view, navigation commands, refresh command, and keyboard shortcuts.
- Preserves: the existing operational service/mount configuration destination in the main window.

- [x] Write failing source-contract tests for the Settings scene, `SettingsLink`, navigation shortcuts, and refresh command.
- [x] Add the dedicated preferences surface and commands using SwiftUI scene APIs.
- [x] Run UI contract tests and build the app target.

### Task 5: Production Release contract

**Files:**
- Create: `scripts/validate-release-app.sh`
- Create: `Tests/BuildScripts/release-app-contract-test.sh`
- Modify: `Makefile`
- Modify: `scripts/notarize-app.sh`
- Modify: `LATCH.xcodeproj/project.pbxproj`
- Modify: `Tests/BuildScripts/xcode-settings-contract-test.sh`
- Modify: `Tests/BuildScripts/xcode-bundle-contract-test.sh`

**Interfaces:**
- Produces: generic-platform universal release build and a reusable distribution preflight validator.
- Requires for a distributable artifact: `arm64 x86_64`, Developer ID Application, runtime flag, valid nested code, and no `get-task-allow`.

- [x] Write failing shell contract tests for the generic destination, disabled Release coverage, validator checks, and notarization preflight.
- [x] Run the script tests and confirm they fail against the development-shaped release path.
- [x] Update build settings and Make targets; implement validator fail-fast behavior and invoke it before notarization.
- [x] Give Xcode settings tests a deterministic derived-data path.
- [x] Run all release/script contract tests, then build an unsigned generic Release artifact to verify both architectures and absent coverage symbols.

### Task 6: Exact build/run integration

**Files:**
- Create: `.codex/environments/environment.toml`
- Create: `Tests/BuildScripts/build-and-run-script-test.sh`
- Modify: `script/build_and_run.sh`
- Modify: `Makefile`

**Interfaces:**
- Produces: an exact staged-executable stop/verify helper and Codex Run action at `./script/build_and_run.sh`.

- [x] Write a failing shell test that supplies controlled process output and proves an unrelated `LATCH` process cannot satisfy verification.
- [x] Update the script to stop before build and verify the exact staged executable path.
- [x] Add the exact environment action format from the Build macOS Apps reference.
- [x] Run the focused script test and `./script/build_and_run.sh --verify`.

### Task 7: Full review and remediation loop

**Files:**
- Modify: any file implicated by fresh review evidence, limited to production-readiness scope.

**Interfaces:**
- Consumes: all prior task outputs.
- Produces: final requirement-to-evidence audit and production-readiness report.

- [x] Run the full Swift test suite, all build-script tests, Debug build, generic Release build, static analysis, bundle validation, exact launch verification, and signature/entitlement inspection.
- [x] Perform a fresh review with Build macOS Apps build, SwiftUI, signing, packaging, test-triage, and run-loop guidance.
- [x] For every new finding, add a focused failing test, implement the fix, rerun affected checks, and repeat the review.
- [x] Perform one additional final review after the first clean verdict.
- [x] Audit every original and newly discovered requirement against fresh authoritative evidence; report any credential-dependent limitation without weakening release gates.
