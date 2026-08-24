# Final Non-Signing Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve every Low-or-higher non-signing finding from the current macOS app review and prove the resulting repository is clean through repeated review and verification.

**Architecture:** Authenticate daemon clients into explicit app and agent roles, recover configuration startup through a quarantining result instead of a silent empty fallback, and keep privacy/accessibility presentation rules in small testable shared policies. SwiftUI retains native macOS structures with limited presentation changes.

**Tech Stack:** Swift 6, SwiftUI, AppKit, NSXPCConnection, ServiceManagement, Swift Testing, Xcode 26.6.

**Spec:** `docs/superpowers/specs/2026-08-24-final-non-signing-remediation-design.md`

## Global Constraints

- macOS deployment target remains 15.0.
- The root daemon must accept only fixed typed requests from authenticated, authorized client roles.
- Configuration corruption must preserve evidence and prevent automatic work from damaged data.
- Stored notification delay values remain seconds for preference compatibility.
- Developer ID signing, notarization, and installed release qualification remain excluded.

---

### Task 1: Role-scoped daemon XPC

**Files:**
- Modify: `Sources/LATCHShared/ClientAuthentication.swift`
- Modify: `Sources/LATCHDaemon/main.swift`
- Test: `Tests/LATCHTests/XPCTests.swift`

**Interfaces:**
- Produces: `DaemonClientRole`, `DaemonXPCOperation`, and `DaemonClientAuthorization.permits(_:for:)`.
- Consumes: existing per-process code-signature validation.
- Preserves: the login agent's read-only status and recent-event requests used for notifications.

- [x] Add failing authorization-matrix tests.
- [x] Run `XPCTests` and confirm the new tests fail for the missing policy.
- [x] Implement the policy and role-specific exported XPC façade.
- [x] Run `XPCTests` and inspect the role routing diff.

### Task 2: Recoverable configuration startup

**Files:**
- Modify: `Sources/LATCHShared/ConfigurationStore.swift`
- Modify: `Sources/LATCHShared/XPCProtocol.swift`
- Modify: `Sources/LATCHDaemon/DaemonController.swift`
- Test: `Tests/LATCHTests/ProbeAndPersistenceTests.swift`

**Interfaces:**
- Produces: a startup-load result containing configuration and persistence health.
- Consumes: `PersistenceHealthSnapshot` and owner-only quarantine behavior.

- [x] Add failing first-run, fallback, double-corruption, quarantine-permission, and health-merge tests.
- [x] Run `ProbeAndPersistenceTests` and confirm the failures describe the missing startup behavior.
- [x] Implement configuration quarantine and startup health reporting.
- [x] Wire merged health and successful-save recovery through the daemon.
- [x] Run the focused persistence tests.

### Task 3: Diagnostics privacy

**Files:**
- Modify: `Sources/LATCHShared/Diagnostics.swift`
- Test: `Tests/LATCHTests/DiagnosticsTests.swift`

**Interfaces:**
- Produces: diagnostics without configured or external NFS export paths.

- [x] Extend the diagnostic test with raw configured and external export paths.
- [x] Confirm the test fails because those paths are currently exported.
- [x] Redact both fields and rerun `DiagnosticsTests`.

### Task 4: Notification delay accessibility

**Files:**
- Modify: `Sources/LATCHShared/NotificationPolicy.swift`
- Modify: `Sources/LATCHApp/SettingsViews+Monitoring.swift`
- Test: `Tests/LATCHTests/NotificationPolicyTests.swift`

**Interfaces:**
- Produces: minute/second conversion and accessibility-value policy used by Settings.

- [x] Add failing conversion and spoken-value tests.
- [x] Implement the minimal policy and minute-based SwiftUI binding.
- [x] Run `NotificationPolicyTests` and inspect the live accessibility tree.

### Task 5: Overview and sparse-table polish

**Files:**
- Modify: `Sources/LATCHShared/OverviewPresentation.swift`
- Modify: `Sources/LATCHApp/SettingsViews+OverviewAndMounts.swift`
- Modify: `Sources/LATCHApp/SettingsViews.swift`
- Test: `Tests/LATCHTests/UIContractTests.swift`

**Interfaces:**
- Produces: explicit Overview header copy and non-striped sparse tables.

- [x] Add a failing Overview-header presentation test.
- [x] Implement the header and disable alternating table backgrounds.
- [x] Run `UIContractTests` and capture fresh Overview, Managed Mounts, and Activity screenshots.

### Task 6: Integrated verification and iterative review

**Files:**
- Modify only if a new validated finding requires remediation.

- [x] Run the complete Xcode test suite and read exact result counts.
- [x] Run Xcode static analysis and all script/packaging contracts.
- [x] Build the unsigned universal Release artifact and inspect all architectures and coverage symbols.
- [x] Review trust boundaries, persistence, lifecycle, cancellation, UI, accessibility, diagnostics, and packaging again.
- [x] For every new Low-or-higher non-signing finding, add a failing regression test, fix it, and repeat the integrated checks.
- [x] Stop only when the fresh review reports no Low-or-higher non-signing findings.
