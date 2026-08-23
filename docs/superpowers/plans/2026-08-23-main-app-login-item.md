# Main-App Login Item Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Launch VACUUM's menu-bar application at user login through the native main-app login service.

**Architecture:** `AppModel` owns `SMAppService.mainApp` beside the existing daemon and agent services. Shared service orchestration treats the three registrations as one setup lifecycle, while daemon and agent online probes remain the runtime health checks. `VACUUMAgent` stops launching the containing application.

**Tech Stack:** Swift 6, SwiftUI, AppKit, ServiceManagement, Swift Testing, macOS 15+

**Spec:** `docs/superpowers/specs/2026-08-23-main-app-login-item.md`

## Global Constraints

- VACUUM remains an `LSUIElement`; login launch must not open or activate the main window.
- Keep the privileged daemon and user-session agent responsibilities unchanged.
- Use `SMAppService.mainApp` for application auto-start; do not retain an `NSWorkspace` fallback or retry loop.
- Preserve the single Monitoring Setup and Remove actions.
- Do not leave a staged VACUUM process running after verification.
- This workspace has no `.git` directory, so the implementation cannot create intermediate commits.

---

### Task 1: Three-service orchestration contract

**Files:**
- Modify: `Tests/VACUUMSharedTests/ServiceManagementTests.swift`
- Modify: `Sources/VACUUMShared/ServicePresentation.swift`

**Interfaces:**
- Consumes: `ManagedServiceControlling`, `ManagedServiceController`
- Produces: three-service `ManagedServicesInstallResult`, `ManagedServicesRepairResult`, `ManagedServicesInstaller`, `ManagedServicesUninstaller`, `ManagedServicesUninstallPlan`, `ManagedServicesPresentation`, and `ManagedServiceRefreshDecision`

- [ ] **Step 1: Write failing tests for the main-app registration**

Add tests which pass a third `FakeManagedService` and assert that combined setup registers it, Ready requires it, repair unregisters and re-registers it, approval refresh remains pending for it, and uninstall includes it.

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `make test FILTER=ServiceManagementTests`

Expected: compilation fails because the orchestration interfaces do not yet accept `mainApplication`.

- [ ] **Step 3: Extend the shared orchestration interfaces**

Add `mainApplication: ManagedServiceState` to presentation and decision inputs. Add a `mainApplication` outcome to install and repair results. Make install, repair, unregistration polling, uninstall, and uninstall planning handle all three services while retaining daemon cleanup rules.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run: `make test FILTER=ServiceManagementTests`

Expected: all service-management tests pass.

### Task 2: Native main-app registration in AppModel

**Files:**
- Modify: `Sources/VACUUMApp/AppModel.swift`
- Modify: `Sources/VACUUMApp/SettingsViews.swift`
- Modify: `Tests/VACUUMSharedTests/UIContractTests.swift`

**Interfaces:**
- Consumes: `SMAppService.mainApp` and the three-service shared orchestration from Task 1
- Produces: `mainApplicationServiceState` and a combined Monitoring Setup lifecycle that manages all three services

- [ ] **Step 1: Write failing UI contract tests**

Update setup-presentation tests to prove that a missing or approval-pending main application prevents Ready and that all three enabled registrations preserve Ready.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `make test FILTER=UIContractTests`

Expected: compilation fails because `ManagedServicesPresentation` does not yet receive the AppModel main-app state at the UI call site.

- [ ] **Step 3: Integrate `SMAppService.mainApp`**

Add `mainApplicationService` and published `mainApplicationServiceState`. Include it in install, repair, approval polling, Ready checks, removal availability, app-replacement preparation, registration fingerprint repair, and authorization synchronization. Treat `serviceStatus.agentAuthorized` as true only when both the login agent and main-app login item are enabled, so Overview setup guidance remains coherent without changing the XPC schema.

- [ ] **Step 4: Pass the state into Settings**

Add `mainApplicationState` to `VACUUMSettingsScreen` and pass it into `ManagedServicesPresentation`.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run: `make test FILTER=UIContractTests`

Expected: all UI contract tests pass.

### Task 3: Remove the agent-to-app handoff

**Files:**
- Modify: `Sources/VACUUMAgent/main.swift`
- Modify: `Sources/VACUUMShared/OverviewPresentation.swift`
- Modify: `Tests/VACUUMSharedTests/UIContractTests.swift`

**Interfaces:**
- Consumes: native main-app registration from Task 2
- Produces: an agent that only runs user-session coordination and post-mount actions

- [ ] **Step 1: Remove the obsolete launch-plan test**

Delete `loginAgentLaunchesTheContainingAppOnlyWhenItIsNotAlreadyRunning`; native login launch is a ServiceManagement boundary and the old test specifies the behavior being removed.

- [ ] **Step 2: Remove the indirect launch code**

Delete `VACUUMLoginItemApplicationLaunchPlan` and the startup `NSWorkspace.openApplication` block from `VACUUMAgent/main.swift`. Retain AppKit imports and post-mount application-opening behavior.

- [ ] **Step 3: Build the affected targets**

Run: `make build CONFIG=debug`

Expected: all targets compile without the removed helper.

### Task 4: Integrated verification and packaging

**Files:**
- Verify only: `Makefile`, `scripts/build-app.sh`, `dist/VACUUM.app`

**Interfaces:**
- Consumes: Tasks 1-3
- Produces: a complete ad-hoc signed app with native login-item registration code

- [ ] **Step 1: Run the complete suite**

Run: `make test`

Expected: all build-script checks and Swift tests pass with zero failures.

- [ ] **Step 2: Build and verify the app**

Run: `make app CONFIG=debug`

Expected: the app is built and ad-hoc signed at `dist/VACUUM.app`; the packaging script's strict checks pass.

- [ ] **Step 3: Inspect the app registration artifacts**

Run: `codesign --verify --deep --strict dist/VACUUM.app` and `plutil -p dist/VACUUM.app/Contents/Library/LaunchAgents/local.vacuum.agent.plist`.

Expected: code-signing verification exits zero and the agent plist remains present for its XPC role.

- [ ] **Step 4: Ensure verification leaves no staged app running**

Run: `pkill -x VACUUM 2>/dev/null || true`

Expected: no `dist/VACUUM.app` process remains. This step does not stop the separately registered agent or daemon.
