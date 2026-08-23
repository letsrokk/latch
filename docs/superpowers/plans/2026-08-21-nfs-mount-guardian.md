# NFS Mount Guardian Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Build a native macOS menu-bar application, privileged daemon, per-user coordinator, and isolated probe that safely manage configured NFS mounts without touching external mounts.

**Architecture:** A Swift package supplies a shared library plus four native executables: the SwiftUI/AppKit menu-bar UI, the root daemon, the per-user coordinator, and the filesystem probe. The shared library owns all typed models, validation, mount inspection, probe classification, persistence, XPC envelopes, and the guarded recovery state machine so these policies can be tested without privileged side effects. A packaging script assembles the executables and service plists into one application bundle for Developer ID signing and `SMAppService` registration.

**Tech Stack:** Swift 6.3, Swift Package Manager, SwiftUI/AppKit, ServiceManagement, Foundation XPC, Security, OSLog, XCTest, Darwin POSIX APIs

**Spec:** `/Users/rokk/Documents/Codex/2026-08-21/on/outputs/nfs-mount-guardian-spec.md`

## Global Constraints

- Target macOS 26 and support native signed executables only; never invoke a shell, `find`, or arbitrary command text.
- Keep the UI unprivileged and route privileged operations through authenticated, size-limited, versioned XPC messages.
- Persist root-owned configuration at `/Library/Application Support/NFSMountGuardian/config.json`, mode `0600`, with atomic replacement and a last-known-good copy.
- Manage mountpoints only below `/Volumes/Media`; reject symlinks, non-empty unmounted directories, duplicate sources or mountpoints, and conflicts with live external mounts.
- Automatically recover only numeric `ESTALE`; never unmount for network loss, timeout, TCC or permission denial, source mismatch, or an unknown error.
- Keep automatic recovery disabled until a probe executed from the registered daemon context proves Network Volumes permission.
- Preserve typed per-volume NFS options, documented recommended defaults, deterministic option order, accessible hints, and optional ordered typed dependencies.
- Treat all pre-existing NFS mounts as read-only external snapshots; never import, probe, mutate, recover, or include them in aggregate health.
- Coordinate only dependencies stored in the selected mount definition and restart only those that were running before the attempt.
- Fail closed after dependencies stop if unmount, remount, source verification, fresh probing, or dependency restart verification fails.

---

### Task 1: Shared domain model and validation

**Files:**
- Create: `Package.swift`
- Create: `Sources/GuardianShared/Models.swift`
- Create: `Sources/GuardianShared/NFSOptions.swift`
- Create: `Sources/GuardianShared/Validation.swift`
- Test: `Tests/GuardianSharedTests/ModelValidationTests.swift`

**Interfaces:**
- Consumes: JSON configuration supplied through XPC or loaded from the daemon-owned store.
- Produces: `MountDefinition`, `NFSOptions`, `RecoveryDependency`, `MountStatus`, `ExternalMountSnapshot`, `ConfigurationValidator.validate(_:liveMounts:)`, and stable `GuardianErrorCode` values.

- [x] **Step 1: Write failing tests for recommended defaults, deterministic option encoding, path normalization, duplicate detection, dependency validation, and external source or mountpoint conflicts.**

```swift
@Test func recommendedOptionsEncodeInStableOrder() {
    #expect(NFSOptions.recommended.encoded == "rw,resvport,tcp,intr,nobrowse,nosuid,nodev")
}

@Test func externalMountpointConflictIsRejected() throws {
    let definition = MountDefinition.fixture(mountPoint: "/Volumes/Media/Movies")
    let external = ExternalMountSnapshot(source: "other:/media", mountPoint: "/Volumes/Media/Movies", fileSystemType: "nfs", options: ["rw"])
    #expect(throws: ConfigurationValidationError.externalMountPointConflict) {
        try ConfigurationValidator().validate([definition], liveMounts: [external])
    }
}
```

- [x] **Step 2: Run `swift test --filter ModelValidationTests` and verify the tests fail because the shared types do not exist.**
- [x] **Step 3: Implement the minimal Codable, Sendable domain types and validation rules needed by the tests.**
- [x] **Step 4: Run `swift test --filter ModelValidationTests` and verify every model and validation test passes.**

### Task 2: Probe, mount snapshots, configuration persistence, and health classification

**Files:**
- Create: `Sources/GuardianShared/Probe.swift`
- Create: `Sources/GuardianShared/MountTable.swift`
- Create: `Sources/GuardianShared/ConfigurationStore.swift`
- Create: `Sources/GuardianProbe/main.swift`
- Test: `Tests/GuardianSharedTests/ProbeAndPersistenceTests.swift`

**Interfaces:**
- Consumes: a mountpoint, raw native errno values, live `statfs` records, and encoded `[MountDefinition]` data.
- Produces: versioned `ProbeResult`, exact errno-to-state classification, `MountTableProviding`, `ConfigurationStore.load/save`, and one JSON probe result on standard output.

- [x] **Step 1: Write failing table-driven tests proving `ESTALE` alone becomes `.stale`, timeout becomes `.probeTimedOut`, network errors become `.networkUnavailable`, permission errors become `.probeError`, and successful metadata plus directory reads become `.healthy`.**
- [x] **Step 2: Write failing persistence tests proving atomic save/load, file mode `0600`, and fallback to `.last-known-good` after primary JSON corruption.**
- [x] **Step 3: Run `swift test --filter ProbeAndPersistenceTests` and verify the failures name the missing classifier and store.**
- [x] **Step 4: Implement the classifier, Darwin mount snapshot adapter, atomic configuration store, and a native probe executable that calls `stat`, `opendir`, and one `readdir` without a shell.**
- [x] **Step 5: Run `swift test --filter ProbeAndPersistenceTests` and verify all focused tests pass.**

### Task 3: Recovery policy and dependency coordination

**Files:**
- Create: `Sources/GuardianShared/RecoveryCoordinator.swift`
- Create: `Sources/GuardianShared/HealthMonitor.swift`
- Test: `Tests/GuardianSharedTests/RecoveryCoordinatorTests.swift`

**Interfaces:**
- Consumes: `MountDefinition`, latest `ProbeResult`, persisted cooldown state, `MountOperating`, and typed `DependencyOperating` adapters.
- Produces: `RecoveryCoordinator.recover(_:trigger:)`, ordered transition events, global serialization, per-mount cooldown enforcement, reverse-order restart, and failed-closed outcomes.

- [x] **Step 1: Write failing tests proving healthy, network, timeout, permission, and unknown results perform no recovery while numeric `ESTALE` enters recovery.**
- [x] **Step 2: Write failing tests proving configured dependencies stop in order, restart in reverse order only when previously running, and a mount with no dependencies performs no dependency operations.**
- [x] **Step 3: Write failing tests proving source mismatch and unresolved dependencies abort before unmount, while any failure after a dependency stops leaves it stopped and reports `.failedClosed`.**
- [x] **Step 4: Run `swift test --filter RecoveryCoordinatorTests` and verify each test fails at the missing policy seam.**
- [x] **Step 5: Implement the actor-based coordinator and health monitor with an injected clock and injected side-effect adapters.**
- [x] **Step 6: Run `swift test --filter RecoveryCoordinatorTests` and verify all focused tests pass.**

### Task 4: Versioned XPC service and native service executables

**Files:**
- Create: `Sources/GuardianShared/XPCProtocol.swift`
- Create: `Sources/GuardianShared/ClientAuthentication.swift`
- Create: `Sources/GuardianDaemon/main.swift`
- Create: `Sources/GuardianAgent/main.swift`
- Test: `Tests/GuardianSharedTests/XPCTests.swift`

**Interfaces:**
- Consumes: encoded `XPCRequestEnvelope` values no larger than 1 MiB and an `NSXPCConnection` audit identity.
- Produces: `GuardianXPCProtocol.handle(_:reply:)`, strict versioned decoding, expected Team ID and bundle-ID authentication, daemon status/CRUD/action/event responses, and typed per-user application lifecycle requests.

- [x] **Step 1: Write failing tests for valid request round trips and rejection of oversized, unsupported-version, malformed, and unauthorized requests.**
- [x] **Step 2: Run `swift test --filter XPCTests` and verify requests fail because the envelope and validator do not exist.**
- [x] **Step 3: Implement the Codable envelope, request router, audit-token signing validator, daemon listener, and per-user application coordinator without accepting executable paths or shell text.**
- [x] **Step 4: Run `swift test --filter XPCTests` and verify all focused tests pass.**

### Task 5: Menu-bar UI, service registration, and bundle packaging

**Files:**
- Create: `Sources/GuardianApp/NFSMountGuardianApp.swift`
- Create: `Sources/GuardianApp/AppModel.swift`
- Create: `Sources/GuardianApp/MountViews.swift`
- Create: `Sources/GuardianApp/SettingsViews.swift`
- Create: `Packaging/App-Info.plist`
- Create: `Packaging/LaunchAgents/local.nfsmountguardian.agent.plist`
- Create: `Packaging/LaunchDaemons/local.nfsmountguardian.daemon.plist`
- Create: `Packaging/Daemon-Info.plist`
- Create: `Packaging/Agent-Info.plist`
- Create: `Packaging/Probe-Info.plist`
- Create: `scripts/build-app.sh`
- Test: `Tests/GuardianSharedTests/UIContractTests.swift`

**Interfaces:**
- Consumes: daemon XPC snapshots and actions plus `SMAppService` authorization state.
- Produces: a `MenuBarExtra` app with managed and external mount views, typed option forms and hints, confirmation gates, recent events, diagnostics, notifications, and a single assembled `NFSMountGuardian.app` containing both service plists and all native executables.

- [x] **Step 1: Write failing contract tests proving each option has the exact accessible hint, Add Mount uses recommended values, Edit Mount preserves stored values, and reset previews only changed values.**
- [x] **Step 2: Run `swift test --filter UIContractTests` and verify the missing presentation model causes failure.**
- [x] **Step 3: Implement the menu-bar app, observable app model, managed/external views, option and dependency editors, confirmation dialogs, authorization remediation, notifications, and redacted diagnostics.**
- [x] **Step 4: Add bundle metadata and service plists using bundle-relative `BundleProgram` values, `LSUIElement`, and `NSNetworkVolumesUsageDescription`; add a deterministic build-and-sign script that refuses release mode without a signing identity.**
- [x] **Step 5: Run `swift test --filter UIContractTests` and verify all UI contract tests pass.**

### Task 6: Integrated verification and operator documentation

**Files:**
- Create: `README.md`
- Create: `docs/system-test-checklist.md`
- Modify: any implementation file implicated by a failing integrated check.

**Interfaces:**
- Consumes: the complete package and a macOS host with Xcode plus a Developer ID identity for signed service-context checks.
- Produces: reproducible local build, unit-test, bundle-build, signing, authorization, Network Volumes gate, controlled recovery, and uninstall instructions.

- [x] **Step 1: Run `swift test` and fix only failures caused by this implementation.**
- [x] **Step 2: Run `swift build -c debug` and verify all four native executables and the shared library compile.**
- [x] **Step 3: Run `scripts/build-app.sh --configuration debug --unsigned` and inspect the bundle layout and all plist files with `plutil -lint`.**
- [x] **Step 4: Run the probe executable against a temporary local directory and verify its versioned JSON reports successful metadata and directory operations.**
- [x] **Step 5: Document the service-context tests that require a signed bundle and administrator approval, including the Network Volumes architectural gate that must pass before enabling recovery.**
- [x] **Step 6: Review the final diff for shell execution, arbitrary options, unsafe mount ownership assumptions, secret paths, unrelated changes, and missing acceptance-criterion coverage.**
