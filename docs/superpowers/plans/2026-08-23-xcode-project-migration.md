# Xcode Project Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace VACUUM's SwiftPM build graph with a native Xcode project, retain Makefile orchestration, adopt the `com.github.letsrokk.vacuum.*` namespace, and relocate the existing Git repository to `/Users/rokk/projects/github/utils/vacuum`.

**Architecture:** One Xcode project owns the app, three helper executables, two static libraries, and the Swift Testing bundle. Xcode assembles and signs the nested app bundle; the Makefile calls `xcodebuild` and stages the resulting app without rebuilding or re-signing it. The existing Git repository remains authoritative throughout migration and moves only after all automated checks pass.

**Tech Stack:** Xcode 26.6, Swift 6.3.3, SwiftUI, Swift Testing, C17, ServiceManagement, `xcodebuild`, zsh, Make.

**Spec:** `docs/superpowers/specs/2026-08-23-xcode-project-migration-design.md`

## Global Constraints

- Preserve macOS 15.0 as the minimum deployment target.
- Use Team ID `DR8RRE2NCU` for Personal Team development signing.
- Use `com.github.letsrokk.vacuum` for the app and that prefix for every helper, service, preferences, logging, and document-type identifier.
- Keep `/Library/Application Support/VACUUM` unchanged.
- Keep helper executables standalone by linking shared code statically.
- Preserve the existing source, unit-test, packaging, documentation, and installed-system behavior unless the spec explicitly changes it.
- Do not perform system cleanup, install into `/Applications`, register services, notarize, push, or commit.
- Do not remove `Package.swift` or relocate the repository until the replacement Xcode checks pass.
- Use `apply_patch` for source and text-file edits. Mechanical icon resizing may use `sips`.

---

### Task 1: Move the Runtime Identity to the GitHub Namespace

**Files:**
- Modify: `Tests/VACUUMSharedTests/BrandingContractTests.swift`
- Modify: `Sources/VACUUMShared/VACUUMIdentity.swift`
- Modify: `Sources/VACUUMDaemon/BonjourDiscovery.swift`
- Modify: `Sources/VACUUMDaemon/NetworkSnapshotProvider.swift`
- Rename: `Packaging/LaunchAgents/local.vacuum.agent.plist` to `Packaging/LaunchAgents/com.github.letsrokk.vacuum.agent.plist`
- Rename: `Packaging/LaunchDaemons/local.vacuum.daemon.plist` to `Packaging/LaunchDaemons/com.github.letsrokk.vacuum.daemon.plist`
- Modify: `Packaging/App-Info.plist`
- Modify: `Sources/VACUUMApp/AppModel.swift`
- Modify: `Sources/VACUUMApp/AppModel+Documents.swift`
- Modify: `Sources/VACUUMShared/ServiceBundleFingerprint.swift`
- Modify: identifier expectations in `Tests/VACUUMSharedTests/ServiceManagementTests.swift`

**Interfaces:**
- Produces: `VACUUMIdentity.bundleIdentifier`, `daemonIdentifier`, `agentIdentifier`, `probeIdentifier`, `preferenceSuite`, and `configurationTypeIdentifier` as the canonical identity API.
- Consumes: no later migration artifact.

- [ ] **Step 1: Write the failing identity contract**

Extend `BrandingContractTests.swift` with exact expectations:

```swift
@Test func reverseDNSIdentifiersUseGitHubNamespace() {
    #expect(VACUUMIdentity.bundleIdentifier == "com.github.letsrokk.vacuum")
    #expect(VACUUMIdentity.daemonIdentifier == "com.github.letsrokk.vacuum.daemon")
    #expect(VACUUMIdentity.agentIdentifier == "com.github.letsrokk.vacuum.agent")
    #expect(VACUUMIdentity.probeIdentifier == "com.github.letsrokk.vacuum.probe")
    #expect(VACUUMIdentity.preferenceSuite == "com.github.letsrokk.vacuum.shared")
    #expect(VACUUMIdentity.configurationTypeIdentifier == "com.github.letsrokk.vacuum.configuration")
}
```

- [ ] **Step 2: Run the focused test and confirm the intended failure**

Run:

```bash
make test FILTER=BrandingContractTests
```

Expected: failure because the existing constants still contain `local.vacuum` and the probe/document-type constants do not yet exist.

- [ ] **Step 3: Implement the canonical identifiers**

Update `VACUUMIdentity` to contain:

```swift
public static let bundleIdentifier = "com.github.letsrokk.vacuum"
public static let daemonIdentifier = "com.github.letsrokk.vacuum.daemon"
public static let agentIdentifier = "com.github.letsrokk.vacuum.agent"
public static let probeIdentifier = "com.github.letsrokk.vacuum.probe"
public static let preferenceSuite = "com.github.letsrokk.vacuum.shared"
public static let configurationTypeIdentifier = "com.github.letsrokk.vacuum.configuration"
```

Replace source-level identifier literals with these constants where a shared dependency is available. Rename both service plists and change their `Label` and `MachServices` values. Change `Packaging/App-Info.plist` to the new bundle and configuration-type identifiers, and change both `SMAppService` plist names to the renamed files.

- [ ] **Step 4: Prove the focused contract and find legacy runtime identifiers**

Run:

```bash
make test FILTER=BrandingContractTests
rg -n 'local\.vacuum' Sources Packaging Tests/VACUUMSharedTests
```

Expected: the test passes. The search returns no active runtime or test expectation; any intentionally retained cleanup documentation is outside these paths.

---

### Task 2: Add a Failing Contract for the Native Xcode Build Graph

**Files:**
- Create: `Tests/BuildScripts/xcode-project-contract-test.sh`
- Create later in this task: `VACUUM.xcodeproj/project.pbxproj`
- Create later in this task: `VACUUM.xcodeproj/xcshareddata/xcschemes/VACUUM.xcscheme`
- Create later in this task: `Sources/VACUUMNative/include/module.modulemap`

**Interfaces:**
- Consumes: canonical identifiers from Task 1.
- Produces: Xcode targets `VACUUM`, `VACUUMDaemon`, `VACUUMAgent`, `VACUUMProbe`, `VACUUMShared`, `VACUUMNative`, and `VACUUMTests`; shared scheme `VACUUM`.

- [ ] **Step 1: Write the project contract test**

Create an executable zsh test that runs `xcodebuild -list -json`, parses it with Ruby's standard `json` library, and checks build settings:

```zsh
#!/bin/zsh
set -euo pipefail

project="$PWD/VACUUM.xcodeproj"
[[ -d "$project" ]]

listing="$(mktemp)"
trap 'rm -f "$listing"' EXIT
xcodebuild -project "$project" -list -json > "$listing"

ruby -rjson -e '
  project = JSON.parse(File.read(ARGV.fetch(0))).fetch("project")
  expected = %w[VACUUM VACUUMAgent VACUUMDaemon VACUUMNative VACUUMProbe VACUUMShared VACUUMTests]
  abort "wrong targets: #{project.fetch("targets").sort.inspect}" unless project.fetch("targets").sort == expected
  abort "VACUUM scheme missing" unless project.fetch("schemes").include?("VACUUM")
' "$listing"

for target in VACUUM VACUUMAgent VACUUMDaemon VACUUMProbe VACUUMShared VACUUMNative VACUUMTests; do
    settings="$(xcodebuild -project "$project" -target "$target" -configuration Debug -showBuildSettings)"
    [[ "$settings" == *'MACOSX_DEPLOYMENT_TARGET = 15.0'* ]]
done

for target in VACUUM VACUUMAgent VACUUMDaemon VACUUMProbe VACUUMShared VACUUMTests; do
    settings="$(xcodebuild -project "$project" -target "$target" -configuration Debug -showBuildSettings)"
    [[ "$settings" == *'SWIFT_VERSION = 6.0'* ]]
done

app_settings="$(xcodebuild -project "$project" -target VACUUM -configuration Debug -showBuildSettings)"
[[ "$app_settings" == *'PRODUCT_BUNDLE_IDENTIFIER = com.github.letsrokk.vacuum'* ]]
[[ "$app_settings" == *'DEVELOPMENT_TEAM = DR8RRE2NCU'* ]]
[[ "$app_settings" == *'ENABLE_APP_SANDBOX = NO'* ]]
```

- [ ] **Step 2: Run the project contract and confirm it fails**

Run:

```bash
Tests/BuildScripts/xcode-project-contract-test.sh
```

Expected: failure because `VACUUM.xcodeproj` does not yet exist in the Git repository.

- [ ] **Step 3: Bring in the template project without its placeholder source**

Copy the unversioned template's `vacuum.xcodeproj` into the Git working tree as `VACUUM.xcodeproj`, excluding `xcuserdata`. Use the generated Xcode 26 object version and Team ID as the base. Do not copy `ContentView.swift`, `vacuumApp.swift`, template tests, or template UI tests.

- [ ] **Step 4: Replace the template targets with the approved target graph**

Define one file-system-synchronized source group per source directory and attach each group only to its matching target. Define `VACUUMShared` and `VACUUMNative` as static-library products. Define the app and three helpers as executable products and the tests as a unit-test bundle.

Apply these common settings:

```text
MACOSX_DEPLOYMENT_TARGET = 15.0
SWIFT_VERSION = 6.0
DEVELOPMENT_TEAM = DR8RRE2NCU
ENABLE_HARDENED_RUNTIME = YES
```

Apply these app settings:

```text
PRODUCT_NAME = VACUUM
PRODUCT_BUNDLE_IDENTIFIER = com.github.letsrokk.vacuum
CODE_SIGN_STYLE = Automatic
ENABLE_APP_SANDBOX = NO
INFOPLIST_FILE = Packaging/App-Info.plist
GENERATE_INFOPLIST_FILE = NO
ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon
```

Apply these helper identifiers:

```text
VACUUMDaemon: com.github.letsrokk.vacuum.daemon
VACUUMAgent:  com.github.letsrokk.vacuum.agent
VACUUMProbe:  com.github.letsrokk.vacuum.probe
```

Link `VACUUMShared` into the app and all helpers. Link `VACUUMNative` into the daemon and probe. Add target dependencies matching those links.

- [ ] **Step 5: Define the C module boundary**

Create `Sources/VACUUMNative/include/module.modulemap`:

```text
module VACUUMNative {
    header "VACUUMNative.h"
    export *
}
```

Set `PUBLIC_HEADERS_FOLDER_PATH`, `HEADER_SEARCH_PATHS`, and `MODULEMAP_FILE` so the daemon and probe continue to compile their existing `import VACUUMNative` statements.

- [ ] **Step 6: Add the shared scheme**

Create `VACUUM.xcodeproj/xcshareddata/xcschemes/VACUUM.xcscheme`. Its Build action builds all production targets in dependency order, its Test action runs `VACUUMTests`, its Run action launches `VACUUM`, and Archive uses Release.

- [ ] **Step 7: Run the project contract until it passes**

Run:

```bash
chmod +x Tests/BuildScripts/xcode-project-contract-test.sh
Tests/BuildScripts/xcode-project-contract-test.sh
```

Expected: all seven exact targets and the shared scheme are present, every deployment target is 15.0, every Swift target uses Swift 6, and the app is unsandboxed with the expected Team and bundle ID.

---

### Task 3: Assemble the Native App Bundle and Asset Catalog

**Files:**
- Create: `Tests/BuildScripts/xcode-bundle-contract-test.sh`
- Modify: `VACUUM.xcodeproj/project.pbxproj`
- Modify: `Packaging/App-Info.plist`
- Create: `Assets.xcassets/Contents.json`
- Create: `Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: ten generated PNG representations under `Assets.xcassets/AppIcon.appiconset/`
- Remove after green: `Tests/BuildScripts/app-icon-packaging-test.sh`
- Remove after green: `scripts/package-app-icon.sh`

**Interfaces:**
- Consumes: helper target products from Task 2.
- Produces: a complete signed `VACUUM.app` in Xcode's build products directory.

- [ ] **Step 1: Write the failing bundle contract**

Create a test accepting the built app path as its only argument. It must assert:

```zsh
#!/bin/zsh
set -euo pipefail

app="${1:?Usage: $0 /path/to/VACUUM.app}"
contents="$app/Contents"

[[ -x "$contents/MacOS/VACUUM" ]]
[[ -x "$contents/Library/Helpers/VACUUMDaemon" ]]
[[ -x "$contents/Library/Helpers/VACUUMAgent" ]]
[[ -x "$contents/Library/Helpers/VACUUMProbe" ]]
[[ -f "$contents/Library/LaunchDaemons/com.github.letsrokk.vacuum.daemon.plist" ]]
[[ -f "$contents/Library/LaunchAgents/com.github.letsrokk.vacuum.agent.plist" ]]

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$contents/Info.plist")" == com.github.letsrokk.vacuum ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$contents/Info.plist")" == 15.0 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :VACUUMTeamIdentifier' "$contents/Info.plist")" == DR8RRE2NCU ]]
[[ -f "$contents/Resources/Assets.car" ]]

codesign --verify --deep --strict --verbose=2 "$app"
```

- [ ] **Step 2: Build once and confirm the bundle contract fails**

Run:

```bash
xcodebuild -project VACUUM.xcodeproj -scheme VACUUM -configuration Debug -derivedDataPath .build/xcode-derived-data build
Tests/BuildScripts/xcode-bundle-contract-test.sh .build/xcode-derived-data/Build/Products/Debug/VACUUM.app
```

Expected: the build or bundle contract fails because copy phases, explicit plist expansion, or app icons are not complete.

- [ ] **Step 3: Add helper and service-plist copy phases**

Add app-target Copy Files phases rooted at the wrapper:

```text
Contents/Library/Helpers:
  VACUUMDaemon (CodeSignOnCopy)
  VACUUMAgent  (CodeSignOnCopy)
  VACUUMProbe  (CodeSignOnCopy)

Contents/Library/LaunchDaemons:
  com.github.letsrokk.vacuum.daemon.plist

Contents/Library/LaunchAgents:
  com.github.letsrokk.vacuum.agent.plist
```

Ensure these phases run before the outer app's final signing step and that every helper target is an explicit dependency.

- [ ] **Step 4: Make the explicit Info.plist build-setting driven**

Use these values in `Packaging/App-Info.plist`:

```xml
<key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
<key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
<key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
<key>LSMinimumSystemVersion</key><string>$(MACOSX_DEPLOYMENT_TARGET)</string>
<key>VACUUMTeamIdentifier</key><string>$(DEVELOPMENT_TEAM)</string>
```

Preserve the existing document, Bonjour, local-network, network-volume, menu-bar, and replacement-preparation keys.

- [ ] **Step 5: Generate the tracked macOS icon representations**

Use `Assets/VACUUM-AppIcon.png` as the 1024-pixel source. Generate the 16, 32, 64, 128, 256, 512, and 1024-pixel files required by the ten macOS asset slots with `sips`, and write exact filename entries into `Assets.xcassets/AppIcon.appiconset/Contents.json`. Add `Assets.xcassets` only to the app target's Resources phase.

- [ ] **Step 6: Prove bundle assembly and remove obsolete icon packaging**

Run the Debug build and bundle contract again. Once it passes, remove the old icon-packaging script and its script-level test, then rerun the bundle contract to prove Xcode owns the icon resource.

---

### Task 4: Run the Existing Swift Testing Suite Through Xcode

**Files:**
- Modify: `VACUUM.xcodeproj/project.pbxproj`
- Modify as required by Xcode module boundaries: `Tests/VACUUMSharedTests/*.swift`

**Interfaces:**
- Consumes: `VACUUMShared` and all existing test files.
- Produces: `VACUUMTests` runnable through the shared scheme without an app host.

- [ ] **Step 1: Run the migrated test target and capture the first real failure**

Run:

```bash
xcodebuild -project VACUUM.xcodeproj -scheme VACUUM -configuration Debug -derivedDataPath .build/xcode-derived-data -destination 'platform=macOS' test
```

Expected: fail if the test bundle still has a template app host, missing target dependency, missing `@testable import VACUUMShared`, or module visibility mismatch.

- [ ] **Step 2: Configure the unit-test target as a logic test**

Remove `TEST_HOST` and `BUNDLE_LOADER`. Link `VACUUMShared`, add it as a target dependency, set `PRODUCT_BUNDLE_IDENTIFIER = com.github.letsrokk.vacuum.tests`, and include only `Tests/VACUUMSharedTests` in the synchronized test group.

- [ ] **Step 3: Make only required source-level module adjustments**

Preserve Swift Testing annotations and behavior. Add `@testable import VACUUMShared` where SwiftPM's implicit package test visibility no longer supplies the module import. Do not convert tests to XCTest.

- [ ] **Step 4: Run focused and full Xcode tests**

Run:

```bash
xcodebuild -project VACUUM.xcodeproj -scheme VACUUM -configuration Debug -derivedDataPath .build/xcode-derived-data -destination 'platform=macOS' -only-testing:VACUUMTests/BrandingContractTests test
xcodebuild -project VACUUM.xcodeproj -scheme VACUUM -configuration Debug -derivedDataPath .build/xcode-derived-data -destination 'platform=macOS' test
```

Expected: the focused identity contract and full Swift Testing suite pass.

---

### Task 5: Replace SwiftPM Make Targets with Xcode Orchestration

**Files:**
- Create: `Tests/BuildScripts/stage-xcode-app-test.sh`
- Create: `scripts/stage-xcode-app.sh`
- Modify: `Makefile`
- Modify: `.gitignore`
- Remove after green: `scripts/build-app.sh`
- Remove after green: `scripts/sign-app.sh`
- Remove after green: `Tests/BuildScripts/adhoc-signing-test.sh`

**Interfaces:**
- Consumes: shared `VACUUM` scheme and Xcode-built app path.
- Produces: stable `make build`, `make test`, `make app`, `make check`, and `make release` commands plus `dist/VACUUM.app`.

- [ ] **Step 1: Write the failing staging-script test**

Create a test that builds two fake app bundles, stages the new one through `scripts/stage-xcode-app.sh`, and asserts the output changed atomically while the source product remains available:

```zsh
#!/bin/zsh
set -euo pipefail

test_root="$(mktemp -d "${TMPDIR:-/tmp}/vacuum-xcode-stage.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/product/VACUUM.app" "$test_root/dist/VACUUM.app"
print new > "$test_root/product/VACUUM.app/version"
print old > "$test_root/dist/VACUUM.app/version"

"$PWD/scripts/stage-xcode-app.sh" "$test_root/product/VACUUM.app" "$test_root/dist"

[[ "$(<"$test_root/dist/VACUUM.app/version")" == new ]]
[[ "$(<"$test_root/product/VACUUM.app/version")" == new ]]
```

- [ ] **Step 2: Run the test and confirm the script is absent**

Run:

```bash
Tests/BuildScripts/stage-xcode-app-test.sh
```

Expected: failure because `scripts/stage-xcode-app.sh` does not exist.

- [ ] **Step 3: Implement atomic staging without re-signing**

The script accepts an existing `.app` and output directory, copies the source with `ditto` into a temporary sibling directory, stops a running copy only when replacing the same executable path, calls `atomic-replace-app.sh`, and verifies the staged signature. It never calls `codesign` and therefore preserves artifact identity.

- [ ] **Step 4: Rewrite Makefile targets around one Xcode invocation contract**

Define:

```make
PROJECT := $(CURDIR)/VACUUM.xcodeproj
SCHEME := VACUUM
DERIVED_DATA := $(CURDIR)/.build/xcode-derived-data
XCODEBUILD := xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -derivedDataPath "$(DERIVED_DATA)"
XCODE_CONFIG := $(if $(filter release,$(CONFIG)),Release,Debug)
BUILT_APP := $(DERIVED_DATA)/Build/Products/$(XCODE_CONFIG)/VACUUM.app
```

Map build and test targets to `$(XCODEBUILD)` with `-destination 'platform=macOS'`. Make `app` depend on the matching build and stage `$(BUILT_APP)`. Make `check` run project-contract, script tests, full unit tests, Debug bundle assembly, and bundle-contract verification.

For `release`, pass the caller's exact `SIGNING_IDENTITY` and `TEAM_ID` as `CODE_SIGN_IDENTITY` and `DEVELOPMENT_TEAM` overrides to a Release build, then stage that exact product. Retain `notarize` and `system-test` as explicit separate targets.

- [ ] **Step 5: Prove Make orchestration before deleting SwiftPM scripts**

Run:

```bash
Tests/BuildScripts/stage-xcode-app-test.sh
make build CONFIG=debug
make test FILTER=BrandingContractTests
make app CONFIG=debug
Tests/BuildScripts/xcode-bundle-contract-test.sh dist/VACUUM.app
```

Expected: all commands pass and the staged signature matches the Xcode product.

- [ ] **Step 6: Remove obsolete SwiftPM assembly and signing paths**

Remove `build-app.sh`, `sign-app.sh`, and the ad-hoc signing test only after Make no longer references them. Keep atomic replacement, running-app shutdown, replacement preparation, notarization, and system-test scripts because their responsibilities remain relevant.

---

### Task 6: Update Documentation and System-Test Contracts

**Files:**
- Modify: `README.md`
- Modify: `docs/system-test-checklist.md`
- Modify: `scripts/system-test.sh`
- Modify: `scripts/check-vacuum-branding.sh`
- Modify: `scripts/check-vacuum-module-names.sh`
- Modify: affected tests under `Tests/BuildScripts/`

**Interfaces:**
- Consumes: new identifiers and Makefile commands.
- Produces: accurate developer, cleanup, packaging, and installed-system instructions.

- [ ] **Step 1: Add failing script expectations for the new namespace**

Update branding/module checks to require `com.github.letsrokk.vacuum` in active package resources and to reject `local.vacuum` in active sources, service plists, and system-test commands. Allow the old namespace only in the explicit manual-cleanup section and historical design documents.

- [ ] **Step 2: Run the checks and confirm stale documentation or commands fail**

Run:

```bash
make branding-check
make module-names-check
```

Expected: failure listing remaining active old identifiers or SwiftPM-specific build instructions.

- [ ] **Step 3: Update the README**

Document Xcode 26.6, macOS 15, Personal Team selection, `make` commands backed by Xcode, `dist/VACUUM.app`, Development versus Developer ID signing, and the approved manual reset procedure:

```bash
launchctl print system/local.vacuum.daemon
launchctl print gui/$(id -u)/local.vacuum.agent
defaults delete local.vacuum
defaults delete local.vacuum.shared
```

State that the first two commands must report the legacy services absent before installing the new build. Describe `/Library/Application Support/VACUUM` removal as optional and destructive; do not automate it.

- [ ] **Step 4: Update installed-system checks**

Replace service labels and preference suites in `scripts/system-test.sh` and `docs/system-test-checklist.md` with:

```text
system/com.github.letsrokk.vacuum.daemon
gui/<uid>/com.github.letsrokk.vacuum.agent
com.github.letsrokk.vacuum.shared
```

- [ ] **Step 5: Rerun branding and script tests**

Run both checks and every retained `Tests/BuildScripts/*.sh`. Expected: all pass.

---

### Task 7: Remove the SwiftPM Build Graph and Verify the Integrated Project

**Files:**
- Remove: `Package.swift`
- Modify: `.gitignore` if Xcode generated paths appear during verification
- Inspect: all current changes

**Interfaces:**
- Consumes: fully working Xcode and Make pipeline.
- Produces: one authoritative build graph ready for relocation.

- [ ] **Step 1: Demonstrate Xcode independence from Package.swift**

Temporarily move `Package.swift` outside the working tree, then run focused Xcode project, build, and test checks. Expected: none attempts Swift package resolution from the removed manifest.

- [ ] **Step 2: Remove Package.swift and scan for SwiftPM commands**

Remove the manifest. Run:

```bash
rg -n 'swift build|swift test|swift package|Package\.swift' Makefile README.md scripts Tests VACUUM.xcodeproj
```

Expected: no active build or documentation reference remains.

- [ ] **Step 3: Run narrow-to-broad verification**

Run:

```bash
Tests/BuildScripts/xcode-project-contract-test.sh
make test FILTER=BrandingContractTests
make test
make app CONFIG=debug
Tests/BuildScripts/xcode-bundle-contract-test.sh dist/VACUUM.app
make app CONFIG=release
Tests/BuildScripts/xcode-bundle-contract-test.sh dist/VACUUM.app
make check CONFIG=debug
```

Expected: all exit successfully. Record Xcode's actual test count, both build results, the four signing identifiers, Team ID, and strict signature-verification result.

- [ ] **Step 4: Inspect repository state**

Run `git status --short`, `git diff --check`, and review the complete diff. Confirm no `xcuserdata`, Derived Data, credentials, provisioning profiles, generated build products, or unrelated edits are tracked.

---

### Task 8: Relocate the Verified Git Repository

**Files and directories:**
- Move: `/Users/rokk/projects/github/utils/nfs-automount` to `/Users/rokk/projects/github/utils/vacuum`
- Remove through replacement: the unversioned Xcode template currently at `/Users/rokk/projects/github/utils/vacuum`

**Interfaces:**
- Consumes: verified working tree from Task 7.
- Produces: one Git working tree at the requested final path with unchanged history and remote.

- [ ] **Step 1: Capture relocation invariants**

Record:

```bash
git rev-parse HEAD
git remote get-url origin
git status --short
```

Confirm the destination is still not a Git repository and contains no user work beyond the Xcode template already incorporated.

- [ ] **Step 2: Request approval for the filesystem relocation**

Because the destination is outside the current writable root and already exists, request escalated approval for these exact directory moves. Do not use recursive deletion.

- [ ] **Step 3: Make the destination recoverable and move the repository**

Move the unversioned destination directory to a uniquely named backup under `/private/tmp`, then move the complete Git working tree to `/Users/rokk/projects/github/utils/vacuum`. Keep the temporary backup until post-move verification passes.

- [ ] **Step 4: Verify identity and build from the final path**

From `/Users/rokk/projects/github/utils/vacuum`, verify the recorded HEAD and remote, inspect `git status`, then run:

```bash
Tests/BuildScripts/xcode-project-contract-test.sh
make test FILTER=BrandingContractTests
make app CONFIG=debug
Tests/BuildScripts/xcode-bundle-contract-test.sh dist/VACUUM.app
```

Expected: repository identity matches the pre-move values and all focused post-move checks pass.

- [ ] **Step 5: Report the recoverable backup and manual system work**

Report the temporary backup path, the uncommitted Git status, and the exact manual `local.vacuum.*` cleanup checklist. Do not run the cleanup or remove the backup in this task.
