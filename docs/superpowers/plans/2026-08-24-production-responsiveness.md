# Production Responsiveness Implementation Plan

Status: implemented and verified on 2026-08-24.

**Goal:** Make LATCH's live state monotonic, monitoring bounded and non-blocking, routine persistence efficient, and its macOS scene structure production-ready.

**Architecture:** The daemon owns a revisioned combined runtime snapshot and publishes it through the authenticated XPC sink. Agent calls gain request-specific deadlines, monitoring uses bounded independent work, and routine runtime writes coalesce without weakening critical persistence. The app applies snapshots monotonically and keeps fallback polling only for reconciliation.

**Tech Stack:** Swift 6, SwiftUI, AppKit, NSXPCConnection, Swift Testing, Xcode 26/macOS 15+

**Spec:** `docs/superpowers/specs/2026-08-24-production-responsiveness-design.md`

## Global Constraints

- Preserve XPC code-signing requirements and the 1 MiB message ceiling.
- Preserve decoding of legacy status-only and event-only sink payloads.
- Keep automatic recovery restricted to numeric `ESTALE`.
- Keep recovery globally serialized and preserve failed-closed dependency handling.
- Do not weaken configuration, mount-target, source-ownership, signing, or release validation.

---

### Task 1: Revisioned Runtime Snapshots

**Files:**
- Modify: `Sources/LATCHShared/XPCProtocol.swift`
- Modify: `Sources/LATCHDaemon/main.swift`
- Modify: `Sources/LATCHDaemon/DaemonController.swift`
- Modify: `Sources/LATCHDaemon/DaemonController+Runtime.swift`
- Modify: `Sources/LATCHApp/AppModel.swift`
- Test: `Tests/LATCHTests/XPCTests.swift`
- Test: `Tests/LATCHTests/UIContractTests.swift`

**Interfaces:**
- Produces: `LATCHRuntimeSnapshot`, revisioned `LATCHStatusSinkUpdate.runtime`, and an app-side monotonic application policy.
- Preserves: legacy `.statuses` and `.events` decoding.

- [x] Add failing codec tests for a combined revisioned snapshot and the message-size limit.
- [x] Add a failing state-policy test proving revision 9 cannot be overwritten by revision 8.
- [x] Implement the snapshot model, codec, daemon revision ownership, initial subscription delivery, and app-side revision gate.
- [x] Run `make test FILTER=XPCTests CONFIG=debug` and `make test FILTER=UIContractTests CONFIG=debug`.

### Task 2: Bounded Agent Requests

**Files:**
- Modify: `Sources/LATCHShared/AgentXPC.swift`
- Modify: `Sources/LATCHDaemon/main.swift`
- Modify: `Sources/LATCHDaemon/DaemonController+Runtime.swift`
- Test: `Tests/LATCHTests/XPCTests.swift`
- Test: `Tests/LATCHTests/RecoveryCoordinatorTests.swift`
- Test: `Tests/LATCHTests/PostMountActionTests.swift`

**Interfaces:**
- Produces: request-specific agent deadline policy and a bounded `ApplicationCoordinatorRequesting` implementation.
- Consumes: existing `ResponseDeadline` and recovery cancellation semantics.

- [x] Add a failing test using a requester that never completes.
- [x] Prove the timeout classifies probes, dependencies, post-mount actions, and reveal requests correctly.
- [x] Add the deadline at the XPC registry boundary and invalidate the timed-out connection.
- [x] Route each request through the correct deadline without shortening joined dependency cleanup.
- [x] Run focused XPC, recovery, and post-mount tests.

### Task 3: Bounded Monitoring Scheduling

**Files:**
- Modify: `Sources/LATCHDaemon/DaemonController+Monitoring.swift`
- Modify: `Sources/LATCHDaemon/DaemonController.swift`
- Test: `Tests/LATCHTests/ProbeAndPersistenceTests.swift`
- Test: `Tests/LATCHTests/NetworkMountRulesTests.swift`

**Interfaces:**
- Produces: a maximum-two due-check scheduler and sweep-scoped hostname reachability cache.
- Preserves: per-mount `MountWorkCoordinator` ownership and global recovery locking.

- [x] Add a deterministic test proving a blocked first mount does not prevent the second mount from completing.
- [x] Add a test proving one hostname is checked once per sweep.
- [x] Implement bounded task scheduling without crossing actor state unsafely.
- [x] Run the focused monitoring and network-rule tests.

### Task 4: Coalesced Runtime Persistence and Honest Clearing

**Files:**
- Modify: `Sources/LATCHShared/ConfigurationStore.swift`
- Modify: `Sources/LATCHDaemon/DaemonController.swift`
- Modify: `Sources/LATCHDaemon/DaemonController+Runtime.swift`
- Test: `Tests/LATCHTests/ProbeAndPersistenceTests.swift`
- Test: `Tests/LATCHTests/UIContractTests.swift`

**Interfaces:**
- Produces: no-op-aware state mutation, coalesced routine persistence, and failure-returning event clearing.

- [x] Add a counting-writer test that fails when one healthy observation causes redundant writes.
- [x] Add a failing daemon-clear policy test for a persistence error.
- [x] Skip unchanged retry mutations and batch routine status persistence.
- [x] Return `.failure(.persistenceFailed, ...)` when event clearing cannot commit.
- [x] Run focused persistence and UI tests.

### Task 5: Main macOS Scene Refactor and Accessibility

**Files:**
- Modify: `Sources/LATCHApp/SettingsViews.swift`
- Modify: `Sources/LATCHApp/SettingsViews+SharedComponents.swift`
- Modify: `Sources/LATCHApp/LATCHApp.swift`
- Modify: `Sources/LATCHApp/MountViews.swift`
- Modify: `Sources/LATCHApp/SettingsViews+Monitoring.swift`
- Test: `Tests/LATCHTests/UIContractTests.swift`

**Interfaces:**
- Produces: a focused main-window root and separately accessible menus/buttons.
- Preserves: all destinations, footer routing, modal behavior, and menu commands.

- [x] Add source-contract tests for the renamed scene and uncombined interactive rows.
- [x] Extract the main root and sidebar while preserving state ownership.
- [x] Remove accessibility combination from rows containing controls and provide explicit summary labels.
- [x] Build and verify the main-window UI contracts.

### Task 6: Performance Telemetry and Integrated Verification

**Files:**
- Modify: daemon and app runtime call sites as required
- Test: relevant contract tests

**Interfaces:**
- Produces: privacy-safe duration, timeout, persistence, and revision telemetry.

- [x] Keep new telemetry events free of raw paths and hostnames.
- [x] Add bounded unified logging around the specified operations.
- [x] Run `make test CONFIG=debug`.
- [x] Run Xcode static analysis and `make check CONFIG=debug`.
- [x] Perform a fresh read-only production review and fix the material defects it finds.
