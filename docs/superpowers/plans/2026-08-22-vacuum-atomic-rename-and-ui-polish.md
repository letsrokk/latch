# VACUUM Atomic Rename and UI Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove obsolete Guardian/NFS Mount Guardian naming throughout the active codebase and deliver the approved folder-picker, monitoring terminology, Support labels, and timing-control behavior.

**Architecture:** Perform the rename in three buildable slices: SwiftPM modules and directories, Swift domain/XPC symbols, then native/packaging/runtime identity cleanup. Add the UI changes only after the renamed build is green, using small shared presentation helpers so folder-picker and duration behavior have deterministic unit tests.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSOpenPanel`, Swift Package Manager, Swift Testing, C/Darwin, ServiceManagement/XPC, zsh packaging scripts, macOS codesign.

**Spec:** `docs/superpowers/specs/2026-08-22-vacuum-atomic-rename-and-ui-polish-design.md`

## Global Constraints

- Keep macOS 15 as the minimum deployment target.
- Keep active identities `local.vacuum`, `local.vacuum.daemon`, `local.vacuum.agent`, and `local.vacuum.shared` unchanged.
- Keep `/Library/Application Support/VACUUM`, `.vacuumconfig`, configuration schema version 2, Codable property names, and enum raw values unchanged.
- Remove compatibility with `local.nfsmountguardian` preferences and `/Library/Application Support/NFSMountGuardian` data.
- Do not change NFS mount, monitoring, recovery, retry, discovery, Wake-on-LAN, or portable-configuration behavior.
- Historical documents may retain old branding; active `Package.swift`, `Sources`, `Tests`, `Packaging`, `scripts`, and `Makefile` may not.
- Use `apply_patch` for source edits. Bulk mechanical path/symbol renames may use `mv` and a repository-scoped mechanical replacement command.
- The current workspace has no `.git` directory. Run the listed commit steps only if execution occurs in a git-enabled checkout; otherwise record each green checkpoint without committing.

---

### Task 1: Rename SwiftPM modules, targets, and source layout

**Files:**
- Create: `scripts/check-vacuum-module-names.sh`
- Modify: `Package.swift`
- Move: `Sources/GuardianShared` → `Sources/VACUUMShared`
- Move: `Sources/GuardianNative` → `Sources/VACUUMNative`
- Move: `Sources/GuardianProbe` → `Sources/VACUUMProbe`
- Move: `Sources/GuardianDaemon` → `Sources/VACUUMDaemon`
- Move: `Sources/GuardianAgent` → `Sources/VACUUMAgent`
- Move: `Sources/GuardianApp` → `Sources/VACUUMApp`
- Move: `Tests/GuardianSharedTests` → `Tests/VACUUMSharedTests`
- Modify: every Swift import under `Sources` and `Tests`
- Modify: `scripts/build-app.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: Existing SwiftPM products and executable assembly contract.
- Produces: `VACUUMShared`, `VACUUMNative`, `VACUUMProbe`, `VACUUMDaemon`, `VACUUMAgent`, `VACUUMApp`, and `VACUUMSharedTests` targets. Swift domain symbols remain unchanged until Task 2.

- [ ] **Step 1: Add a failing module-name contract**

Create `scripts/check-vacuum-module-names.sh`:

```zsh
#!/bin/zsh
set -euo pipefail

old_prefix="Guar""dian"
failures=""
for path in Sources/${old_prefix}*(N) Tests/${old_prefix}*(N); do
    [[ -e "$path" ]] && failures+="$path\n"
done
pattern="(^|@testable )[[:space:]]*import ${old_prefix}(Shared|Native)|name: \"${old_prefix}(Shared|Native|Probe|Daemon|Agent|App)\"|/${old_prefix}(App|Daemon|Agent|Probe)\""
matches="$(rg -n "$pattern" Package.swift Sources Tests scripts 2>/dev/null || true)"
[[ -n "$matches" ]] && failures+="$matches\n"

if [[ -n "$failures" ]]; then
    print -u2 -- "Obsolete Guardian module names remain:"
    print -u2 -r -- "$failures"
    exit 1
fi
```

Make it executable and add a `module-names-check` Make target that calls it.

- [ ] **Step 2: Run the contract and verify it fails for current module names**

Run: `make module-names-check`

Expected: exit 1 with `Sources/Guardian*`, `Tests/Guardian*`, `Package.swift`, imports, and build-script binary names reported.

- [ ] **Step 3: Rename target directories and package declarations**

Move the seven directories listed above. Update `Package.swift` so all products, targets, dependencies, and the test target use the final VACUUM names:

```swift
products: [
    .library(name: "VACUUMShared", targets: ["VACUUMShared"]),
    .executable(name: "VACUUMProbe", targets: ["VACUUMProbe"]),
    .executable(name: "VACUUMDaemon", targets: ["VACUUMDaemon"]),
    .executable(name: "VACUUMAgent", targets: ["VACUUMAgent"]),
    .executable(name: "VACUUMApp", targets: ["VACUUMApp"]),
],
targets: [
    .target(name: "VACUUMShared"),
    .target(name: "VACUUMNative", publicHeadersPath: "include"),
    .executableTarget(name: "VACUUMProbe", dependencies: ["VACUUMShared", "VACUUMNative"]),
    .executableTarget(name: "VACUUMDaemon", dependencies: ["VACUUMShared", "VACUUMNative"]),
    .executableTarget(name: "VACUUMAgent", dependencies: ["VACUUMShared"]),
    .executableTarget(name: "VACUUMApp", dependencies: ["VACUUMShared"]),
    .testTarget(name: "VACUUMSharedTests", dependencies: ["VACUUMShared"]),
]
```

Update imports to `VACUUMShared` and `VACUUMNative`. Update `scripts/build-app.sh` to copy `VACUUMApp`, `VACUUMDaemon`, `VACUUMAgent`, and `VACUUMProbe` from the SwiftPM binary directory.

- [ ] **Step 4: Run module contract and full compile**

Run: `make module-names-check`

Expected: PASS.

Run: `make build CONFIG=debug`

Expected: all renamed SwiftPM targets compile successfully.

- [ ] **Step 5: Commit the module rename when git is available**

```bash
git add Package.swift Sources Tests scripts/build-app.sh scripts/check-vacuum-module-names.sh Makefile
git commit -m "refactor: rename package modules to VACUUM"
```

---

### Task 2: Rename Swift domain, presentation, and XPC symbols

**Files:**
- Rename: `Sources/VACUUMShared/GuardianDaemonRequestClient.swift` → `Sources/VACUUMShared/VACUUMDaemonRequestClient.swift`
- Rename: `Sources/VACUUMApp/NFSMountGuardianApp.swift` → `Sources/VACUUMApp/VACUUMApp.swift`
- Modify: all Swift files under `Sources/VACUUMShared`, `Sources/VACUUMApp`, `Sources/VACUUMAgent`, `Sources/VACUUMDaemon`, and `Tests/VACUUMSharedTests`
- Test: `Tests/VACUUMSharedTests/BrandingContractTests.swift`

**Interfaces:**
- Consumes: VACUUM module names from Task 1.
- Produces: `VACUUMConfiguration`, `VACUUMEvent`, `VACUUMErrorCode`, `VACUUMAction`, `VACUUMRequest`, `VACUUMResponse`, `VACUUMXPCProtocol`, `VACUUMStatusSink`, `VACUUMAgentXPCProtocol`, `VACUUMDaemonRequestClient`, `VACUUMDaemonRequestClientError`, `VACUUMNotificationEvent`, `VACUUMSetupRequirement`, `VACUUMOverview`, `VACUUMMenuHeaderPresentation`, `VACUUMPreviewFixture`, `VACUUMMenu`, `VACUUMDestination`, and `VACUUMSettingsScreen`.

- [ ] **Step 1: Add a compile-time test for the final public names**

Create `BrandingContractTests.swift`:

```swift
import Foundation
import Testing
@testable import VACUUMShared

@Suite("VACUUM branding contracts")
struct BrandingContractTests {
    @Test func finalDomainAndXPCNamesAreAvailable() {
        let configuration = VACUUMConfiguration()
        let request = VACUUMRequest.getConfiguration
        let event = VACUUMEvent(
            date: Date(timeIntervalSince1970: 0),
            mountID: nil,
            state: nil,
            code: VACUUMErrorCode.none,
            detail: "Ready"
        )

        #expect(configuration.schemaVersion == 2)
        #expect(request == .getConfiguration)
        #expect(event.code == .none)
    }
}
```

- [ ] **Step 2: Run the focused test and verify compilation fails for missing VACUUM symbols**

Run: `make test FILTER=BrandingContractTests`

Expected: compile failure reporting missing `VACUUMConfiguration`, `VACUUMRequest`, or `VACUUMEvent`.

- [ ] **Step 3: Apply the exact Swift symbol map atomically**

Apply these global identifier-only replacements in active Swift source and tests:

```text
GuardianConfiguration             VACUUMConfiguration
GuardianEvent                     VACUUMEvent
GuardianErrorCode                 VACUUMErrorCode
GuardianAction                    VACUUMAction
GuardianRequest                   VACUUMRequest
GuardianResponse                  VACUUMResponse
GuardianXPCProtocol               VACUUMXPCProtocol
GuardianStatusSink                VACUUMStatusSink
GuardianAgentXPCProtocol          VACUUMAgentXPCProtocol
GuardianDaemonRequestClient       VACUUMDaemonRequestClient
GuardianDaemonRequestClientError  VACUUMDaemonRequestClientError
GuardianNotificationEvent         VACUUMNotificationEvent
GuardianSetupRequirement          VACUUMSetupRequirement
GuardianOverview                  VACUUMOverview
GuardianMenuHeaderPresentation    VACUUMMenuHeaderPresentation
GuardianPreviewFixture            VACUUMPreviewFixture
GuardianMenu                      VACUUMMenu
GuardianDestination               VACUUMDestination
GuardianSettingsScreen            VACUUMSettingsScreen
```

Rename the two branding-bearing filenames listed above. Update every `NSXPCInterface(with:)`, exported/remote protocol cast, request/response signature, preview fixture, notification identifier construction, and test reference to the final type names. Do not alter Codable case names or raw values.

- [ ] **Step 4: Run XPC, persistence, and branding tests**

Run: `make test FILTER='BrandingContractTests|XPCTests|ProbeAndPersistenceTests|UIContractTests'`

Expected: all selected suites pass; XPC request/response round trips and schema behavior remain unchanged.

- [ ] **Step 5: Commit the Swift symbol rename when git is available**

```bash
git add Sources Tests
git commit -m "refactor: rename Guardian symbols to VACUUM"
```

---

### Task 3: Rename native symbols and packaging identity; remove legacy migration

**Files:**
- Rename: `Sources/VACUUMNative/GuardianNative.c` → `Sources/VACUUMNative/VACUUMNative.c`
- Rename: `Sources/VACUUMNative/include/GuardianNative.h` → `Sources/VACUUMNative/include/VACUUMNative.h`
- Modify: `Sources/VACUUMNative/VACUUMNative.c`
- Modify: `Sources/VACUUMNative/include/VACUUMNative.h`
- Modify: `Sources/VACUUMProbe/main.swift`
- Modify: `Sources/VACUUMDaemon/SystemOperations.swift`
- Modify: `Sources/VACUUMShared/VACUUMIdentity.swift`
- Modify: `Sources/VACUUMShared/ConfigurationStore.swift`
- Modify: `Sources/VACUUMApp/AppModel.swift`
- Modify: `Packaging/App-Info.plist`
- Modify: `scripts/build-app.sh`
- Modify: `scripts/sign-app.sh`
- Create: `scripts/check-vacuum-branding.sh`
- Test: `Tests/VACUUMSharedTests/ProbeAndPersistenceTests.swift`
- Test: `Tests/VACUUMSharedTests/BrandingContractTests.swift`

**Interfaces:**
- Consumes: final VACUUM Swift module and symbol names.
- Produces: C exports `vacuum_stat_path`, `vacuum_lstat_path`, and `vacuum_tcp_check`; Info.plist key `VACUUMTeamIdentifier`; VACUUM-only preferences and persistence directories.

- [ ] **Step 1: Add failing identity and migration-removal contracts**

Extend `BrandingContractTests`:

```swift
@Test func activeIdentityUsesOnlyVacuumPathsAndIdentifiers() {
    #expect(VACUUMIdentity.preferenceSuite == "local.vacuum.shared")
    #expect(VACUUMIdentity.applicationSupportDirectory.path == "/Library/Application Support/VACUUM")
}
```

Delete the two tests that assert NFSMountGuardian directory/preference migration. Add a replacement persistence test that constructs `ConfigurationStore(directory:)` and `RecoveryStateStore(directory:)`, saves VACUUM state, reloads it, and asserts the same values without a legacy-directory argument.

Create `scripts/check-vacuum-branding.sh`:

```zsh
#!/bin/zsh
set -euo pipefail

obsolete_pattern='guar''dian|nfsmount''guardian|guar''dian_'
matches="$(rg -n -i "$obsolete_pattern" Package.swift Sources Tests Packaging scripts Makefile 2>/dev/null || true)"
if [[ -n "$matches" ]]; then
    print -u2 -- "Obsolete product branding remains:"
    print -u2 -r -- "$matches"
    exit 1
fi
```

Add `branding-check` to `Makefile`, and add it as a prerequisite of `check`.

- [ ] **Step 2: Run the branding and persistence contracts and verify they fail**

Run: `make branding-check`

Expected: FAIL on native filenames/symbols, Team Identifier key, legacy identity/migration code, or remaining active Guardian text.

Run: `make test FILTER='BrandingContractTests|ProbeAndPersistenceTests'`

Expected: the replacement tests characterize active VACUUM persistence and pass. The required red evidence for this removal slice is the failing branding contract above.

- [ ] **Step 3: Rename native files and exports**

Use this final header surface:

```c
#ifndef VACUUM_NATIVE_H
#define VACUUM_NATIVE_H

#include <sys/stat.h>

int vacuum_stat_path(const char *path, struct stat *result);
int vacuum_lstat_path(const char *path, struct stat *result);
int vacuum_tcp_check(const char *host, unsigned short port, int timeout_milliseconds);

#endif
```

Update the C implementation include and function names. Update Swift call sites in the probe and daemon system operations.

- [ ] **Step 4: Rename the signing metadata key and remove legacy migration**

Change `GuardianTeamIdentifier` to `VACUUMTeamIdentifier` in App-Info.plist, both scripts, and `AppModel` runtime lookup.

Remove from `VACUUMIdentity`:

```swift
legacyPreferenceSuite
legacyApplicationSupportDirectory
PreferenceMigrator
```

Remove preference copying from `AppModel.init()`. Simplify both stores to VACUUM-only initialization:

```swift
public init() {
    self.init(directory: VACUUMIdentity.applicationSupportDirectory)
}

public init(directory: URL) {
    self.directory = directory
    // RecoveryStateStore also initializes stateURL and state here.
}
```

Remove the `legacyDirectory` overloads and directory-copy calls. Keep schema-1-to-schema-2 configuration migration because it is a data-schema migration, not a branding migration.

- [ ] **Step 5: Run branding, persistence, XPC, and full compile checks**

Run: `make branding-check`

Expected: PASS with no obsolete branding in active code and packaging.

Run: `make test FILTER='BrandingContractTests|ProbeAndPersistenceTests|XPCTests'`

Expected: PASS.

Run: `make build CONFIG=debug`

Expected: PASS for all Swift and native targets.

- [ ] **Step 6: Commit native and identity cleanup when git is available**

```bash
git add Sources Tests Packaging scripts Makefile
git commit -m "refactor: remove legacy Guardian identity"
```

---

### Task 4: Replace protection terminology and Support labels

**Files:**
- Modify: `Sources/VACUUMShared/OverviewPresentation.swift`
- Modify: `Sources/VACUUMShared/EditorPresentation.swift`
- Modify: `Sources/VACUUMApp/MountViews.swift`
- Modify: `Sources/VACUUMApp/SettingsViews.swift`
- Test: `Tests/VACUUMSharedTests/UIContractTests.swift`

**Interfaces:**
- Consumes: VACUUM presentation types from Task 2.
- Produces: `VACUUMInterfaceCopy`, a single source for monitoring-setup and Support action labels.

- [ ] **Step 1: Add failing copy contracts**

Add to `UIContractTests`:

```swift
@Test func monitoringSetupAndSupportCopyUsesFinalLabels() {
    #expect(VACUUMInterfaceCopy.setupSectionTitle == "Monitoring Setup")
    #expect(VACUUMInterfaceCopy.setupRequiredTitle == "Monitoring needs setup")
    #expect(VACUUMInterfaceCopy.exportDiagnosticsTitle == "Export Diagnostics")
    #expect(VACUUMInterfaceCopy.exportConfigurationTitle == "Export Configuration")
    #expect(VACUUMInterfaceCopy.importConfigurationTitle == "Import Configuration")
}
```

- [ ] **Step 2: Run the focused test and verify it fails for missing copy API**

Run: `make test FILTER=UIContractTests`

Expected: compile failure because `VACUUMInterfaceCopy` does not exist.

- [ ] **Step 3: Add the copy API and consume it in both app surfaces**

Add to `EditorPresentation.swift`:

```swift
public enum VACUUMInterfaceCopy {
    public static let setupSectionTitle = "Monitoring Setup"
    public static let setupRequiredTitle = "Monitoring needs setup"
    public static let exportDiagnosticsTitle = "Export Diagnostics"
    public static let exportConfigurationTitle = "Export Configuration"
    public static let importConfigurationTitle = "Import Configuration"
}
```

Use these constants in main Settings, Overview, and the menu-bar setup card. Retain existing automatic-recovery explanations but remove claims that VACUUM “protects” a volume.

- [ ] **Step 4: Run copy and branding checks**

Run: `make test FILTER=UIContractTests`

Expected: PASS.

Run: `make branding-check`

Expected: PASS.

- [ ] **Step 5: Commit the terminology update when git is available**

```bash
git add Sources/VACUUMShared Sources/VACUUMApp Tests/VACUUMSharedTests
git commit -m "refactor: use monitoring terminology"
```

---

### Task 5: Reopen the mount-folder picker at the selected folder

**Files:**
- Modify: `Sources/VACUUMShared/EditorPresentation.swift`
- Modify: `Sources/VACUUMApp/SettingsViews.swift`
- Test: `Tests/VACUUMSharedTests/UIContractTests.swift`

**Interfaces:**
- Consumes: `MountDraft.mountPoint`, current `mountTargetConfirmed`, and user home URL.
- Produces: `MountFolderPickerPresentation.initialDirectory(mountPoint:homeDirectory:confirmed:) -> URL` and `MountFolderPickerPresentation.message`.

- [ ] **Step 1: Add failing folder-picker presentation tests**

Add to `UIContractTests`:

```swift
@Test func folderPickerStartsAtHomeUntilASelectionIsConfirmed() {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    #expect(MountFolderPickerPresentation.initialDirectory(
        mountPoint: "/Users/test/Music",
        homeDirectory: home,
        confirmed: false
    ) == home.standardizedFileURL)
}

@Test func folderPickerReopensAtTheConfirmedFolder() {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    let selected = URL(fileURLWithPath: "/Users/test/Music", isDirectory: true).standardizedFileURL
    #expect(MountFolderPickerPresentation.initialDirectory(
        mountPoint: selected.path,
        homeDirectory: home,
        confirmed: true
    ) == selected)
    #expect(MountFolderPickerPresentation.message == "Choose an existing empty folder.")
}
```

- [ ] **Step 2: Run tests and verify they fail for the missing picker presentation**

Run: `make test FILTER=UIContractTests`

Expected: compile failure because `MountFolderPickerPresentation` is missing.

- [ ] **Step 3: Implement the deterministic picker presentation**

Add:

```swift
public enum MountFolderPickerPresentation {
    public static let message = "Choose an existing empty folder."

    public static func initialDirectory(
        mountPoint: String,
        homeDirectory: URL,
        confirmed: Bool
    ) -> URL {
        guard confirmed, !mountPoint.isEmpty else { return homeDirectory.standardizedFileURL }
        return URL(fileURLWithPath: mountPoint, isDirectory: true).standardizedFileURL
    }
}
```

In `chooseMountFolder()`, set:

```swift
panel.message = MountFolderPickerPresentation.message
panel.directoryURL = MountFolderPickerPresentation.initialDirectory(
    mountPoint: draft.mountPoint,
    homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
    confirmed: mountTargetConfirmed
)
```

Keep assigning `draft.mountPoint` and `mountTargetConfirmed = true` only after validator success. Returning on Cancel therefore preserves the previous selection and starting directory.

- [ ] **Step 4: Run folder-picker and mount-target tests**

Run: `make test FILTER='UIContractTests|MountTargetTests'`

Expected: PASS.

- [ ] **Step 5: Commit folder-picker behavior when git is available**

```bash
git add Sources/VACUUMShared/EditorPresentation.swift Sources/VACUUMApp/SettingsViews.swift Tests/VACUUMSharedTests/UIContractTests.swift
git commit -m "fix: reopen mount picker at selected folder"
```

---

### Task 6: Give monitoring timing controls explicit values and steppers

**Files:**
- Modify: `Sources/VACUUMShared/EditorPresentation.swift`
- Modify: `Sources/VACUUMApp/SettingsViews.swift`
- Test: `Tests/VACUUMSharedTests/UIContractTests.swift`

**Interfaces:**
- Consumes: `MountDraft.probeIntervalSeconds`, `probeTimeoutSeconds`, and `recoveryCooldownSeconds`.
- Produces: `MountTimingPresentation` and private SwiftUI `OutlinedNumericStepperRow`.

- [ ] **Step 1: Add failing timing presentation tests**

Add to `UIContractTests`:

```swift
@Test func mountTimingPresentationKeepsUnitsRangesAndCooldownConversion() {
    let fields = MountTimingPresentation.fields(
        probeIntervalSeconds: 60,
        probeTimeoutSeconds: 5,
        recoveryCooldownSeconds: 600
    )

    #expect(fields == [
        .init(kind: .probeInterval, title: "Probe interval", value: 60, unit: "seconds", range: 10...3600, step: 10),
        .init(kind: .probeTimeout, title: "Probe timeout", value: 5, unit: "seconds", range: 1...30, step: 1),
        .init(kind: .recoveryCooldown, title: "Recovery cooldown", value: 10, unit: "minutes", range: 1...1440, step: 1),
    ])
    #expect(MountTimingPresentation.storedSeconds(for: .recoveryCooldown, displayedValue: 10) == 600)
}
```

- [ ] **Step 2: Run tests and verify they fail for the missing presentation model**

Run: `make test FILTER=UIContractTests`

Expected: compile failure because `MountTimingPresentation` is missing.

- [ ] **Step 3: Add the timing presentation model**

Implement these presentation types and function:

```swift
public enum MountTimingKind: Sendable, Equatable {
    case probeInterval
    case probeTimeout
    case recoveryCooldown
}

public struct MountTimingFieldPresentation: Sendable, Equatable {
    public let kind: MountTimingKind
    public let title: String
    public let value: Int
    public let unit: String
    public let range: ClosedRange<Int>
    public let step: Int

    public init(kind: MountTimingKind, title: String, value: Int, unit: String, range: ClosedRange<Int>, step: Int) {
        self.kind = kind
        self.title = title
        self.value = value
        self.unit = unit
        self.range = range
        self.step = step
    }
}
```

Then add:

```swift
public enum MountTimingPresentation {
    public static func fields(
        probeIntervalSeconds: Int,
        probeTimeoutSeconds: Int,
        recoveryCooldownSeconds: Int
    ) -> [MountTimingFieldPresentation] {
        [
            .init(kind: .probeInterval, title: "Probe interval", value: probeIntervalSeconds, unit: "seconds", range: 10...3600, step: 10),
            .init(kind: .probeTimeout, title: "Probe timeout", value: probeTimeoutSeconds, unit: "seconds", range: 1...30, step: 1),
            .init(kind: .recoveryCooldown, title: "Recovery cooldown", value: recoveryCooldownSeconds / 60, unit: "minutes", range: 1...1440, step: 1),
        ]
    }

    public static func storedSeconds(for kind: MountTimingKind, displayedValue: Int) -> Int {
        kind == .recoveryCooldown ? displayedValue * 60 : displayedValue
    }
}
```

- [ ] **Step 4: Replace label-style steppers with the shared row**

Add a private `OutlinedNumericStepperRow` in `SettingsViews.swift`:

```swift
private struct OutlinedNumericStepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String

    var body: some View {
        HStack(spacing: 8) {
            Text("\(title):")
            Spacer()
            Text("\(value)")
                .monospacedDigit()
                .frame(minWidth: 42)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator.opacity(0.9)))
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("\(title) in \(unit)")
            Text(unit)
        }
    }
}
```

Use direct bindings for interval and timeout. Use a computed `Binding<Int>` for cooldown minutes that reads `recoveryCooldownSeconds / 60` and writes `newValue * 60`.

- [ ] **Step 5: Run timing and validation tests**

Run: `make test FILTER='UIContractTests|ModelValidationTests'`

Expected: PASS with existing probe-timeout validation unchanged.

- [ ] **Step 6: Commit timing controls when git is available**

```bash
git add Sources/VACUUMShared/EditorPresentation.swift Sources/VACUUMApp/SettingsViews.swift Tests/VACUUMSharedTests/UIContractTests.swift
git commit -m "feat: clarify mount timing controls"
```

---

### Task 7: Exhaustive verification and packaged app handoff

**Files:**
- Verify: `Package.swift`, `Sources`, `Tests`, `Packaging`, `scripts`, `Makefile`
- Build: `dist/VACUUM.app`

**Interfaces:**
- Consumes: all completed rename and UI slices.
- Produces: an ad-hoc signed, strictly verified VACUUM app with no running test-app process.

- [ ] **Step 1: Run obsolete-branding and whitespace checks**

Run: `make module-names-check branding-check`

Expected: PASS.

If git is available, run: `git diff --check`

Expected: no whitespace errors or conflict markers.

- [ ] **Step 2: Run the full verification target**

Run: `make check CONFIG=debug`

Expected: every Swift test suite passes, all renamed targets compile, and `dist/VACUUM.app` is rebuilt and ad-hoc signed.

- [ ] **Step 3: Inspect packaged identities and helper paths**

Run:

```zsh
plutil -p dist/VACUUM.app/Contents/Info.plist
find dist/VACUUM.app/Contents/Library/Helpers -maxdepth 1 -type f -print
```

Expected:

- Info.plist contains `VACUUMTeamIdentifier` and no Guardian key.
- Helpers are exactly `VACUUMAgent`, `VACUUMDaemon`, and `VACUUMProbe`.
- Bundle and service identifiers remain `local.vacuum*`.

- [ ] **Step 4: Strictly verify the signature**

Run: `codesign --verify --deep --strict --verbose=2 dist/VACUUM.app`

Expected: `valid on disk` and `satisfies its Designated Requirement`.

- [ ] **Step 5: Ensure the test app is closed**

Run: `ps -axo pid=,command=` and identify only processes whose command contains the explicit path `nfs-automount/dist/VACUUM.app/Contents/MacOS/VACUUM`.

If present, send `TERM` to only those exact PIDs. Re-run the process check.

Expected: no process remains for the rebuilt app path. Do not unregister or stop the separately installed VACUUM daemon or login agent during this check.

- [ ] **Step 6: Commit the final integrated state when git is available**

```bash
git add Package.swift Sources Tests Packaging scripts Makefile docs/superpowers
git commit -m "feat: complete VACUUM rename and UI polish"
```
