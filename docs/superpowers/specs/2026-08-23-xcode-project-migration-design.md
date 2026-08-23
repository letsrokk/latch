# Xcode Project Migration Design

## Goal

Consolidate VACUUM into `/Users/rokk/projects/github/utils/vacuum` as one Git repository whose authoritative build graph is a native Xcode project. Preserve the existing `Makefile` as the terminal interface, preserve repository history and `origin`, and remove the old `nfs-automount` working-tree path only after the new project verifies successfully.

## Current State

The existing `nfs-automount` Git repository builds VACUUM through Swift Package Manager and custom bundle scripts. It contains a SwiftUI menu-bar application, a privileged daemon, a user-session agent, a native probe, shared Swift code, a C module, Swift Testing tests, packaging resources, and installed-system checks.

The new `vacuum` directory contains an unversioned Xcode template with one macOS app target, template unit and UI tests, automatic Personal Team signing, and placeholder sources. Its template identifiers and deployment settings do not match VACUUM.

## Architecture

`VACUUM.xcodeproj` becomes the sole definition of targets, dependencies, bundle assembly, and code signing. `Package.swift` is removed only after Xcode builds and tests the migrated source successfully.

The Xcode project contains these targets:

- `VACUUM`: macOS SwiftUI application.
- `VACUUMDaemon`: command-line executable installed as a privileged LaunchDaemon.
- `VACUUMAgent`: command-line executable installed as a per-user LaunchAgent.
- `VACUUMProbe`: command-line executable used for isolated filesystem probes.
- `VACUUMShared`: Swift static library linked into the application and helper executables.
- `VACUUMNative`: C static library linked into the daemon and probe.
- `VACUUMTests`: macOS unit-test bundle containing the existing Swift Testing suite.

Static libraries preserve the current standalone-helper model. The deployed helpers do not depend on a separately embedded dynamic framework.

## Repository Layout

The consolidated repository keeps the existing source-oriented layout:

```text
vacuum/
├── VACUUM.xcodeproj
├── Sources/
│   ├── VACUUMApp/
│   ├── VACUUMDaemon/
│   ├── VACUUMAgent/
│   ├── VACUUMProbe/
│   ├── VACUUMShared/
│   └── VACUUMNative/
├── Tests/
│   ├── VACUUMSharedTests/
│   └── BuildScripts/
├── Packaging/
├── Assets/
├── scripts/
├── docs/
├── Makefile
└── README.md
```

The generated `vacuum`, `vacuumTests`, and `vacuumUITests` template directories are removed after the real targets replace their contents. The existing Git history and `origin` move with the working tree.

## Identifier Namespace

All reverse-DNS identifiers use the new namespace:

```text
com.github.letsrokk.vacuum
com.github.letsrokk.vacuum.daemon
com.github.letsrokk.vacuum.agent
com.github.letsrokk.vacuum.probe
com.github.letsrokk.vacuum.shared
com.github.letsrokk.vacuum.configuration
```

This namespace applies to:

- application and helper code-signing identifiers;
- LaunchAgent and LaunchDaemon labels and plist filenames;
- XPC Mach service names;
- the shared preferences suite;
- the exported configuration document type;
- logging subsystems and internal dispatch queue labels where they currently use the old namespace;
- tests, scripts, documentation, and system-test commands.

The root-owned configuration path remains `/Library/Application Support/VACUUM` because it is a product data path rather than an identity namespace.

## Compatibility Policy

This migration is a clean development reset. The new application does not include runtime compatibility code, legacy service plists, or automatic preference migration for `local.vacuum.*`.

Before testing the new build, the developer manually:

1. disables Start at Login in the old application;
2. removes the old daemon and agent from the old application Settings screen;
3. verifies that `system/local.vacuum.daemon` and `gui/<uid>/local.vacuum.agent` are absent;
4. removes the old `/Applications/VACUUM.app`;
5. deletes the `local.vacuum` and `local.vacuum.shared` defaults domains;
6. optionally archives or removes `/Library/Application Support/VACUUM` for a fully empty configuration;
7. disables any stale VACUUM entry in System Settings under Login Items & Extensions.

The repository README records this procedure. The migration does not execute these destructive cleanup actions.

## Bundle Assembly

The `VACUUM` app target depends on the daemon, agent, and probe targets. Its build phases assemble this layout:

```text
VACUUM.app/
└── Contents/
    ├── MacOS/VACUUM
    ├── Library/
    │   ├── Helpers/
    │   │   ├── VACUUMDaemon
    │   │   ├── VACUUMAgent
    │   │   └── VACUUMProbe
    │   ├── LaunchAgents/com.github.letsrokk.vacuum.agent.plist
    │   └── LaunchDaemons/com.github.letsrokk.vacuum.daemon.plist
    └── Resources/
```

Xcode copies the helper target products into `Contents/Library/Helpers` and preserves their individual code signatures. It copies the service plists into their required `Contents/Library` subdirectories and signs the outer application after nested code is in place.

The application uses an explicit Info.plist derived from the existing packaging plist. It preserves the menu-bar-only behavior, Bonjour declarations, network-volume usage description, document type, version keys, minimum system version, and the custom Team ID value used by XPC authentication.

The existing 1024-pixel icon source populates all required macOS slots in the Xcode asset catalog. Xcode compiles the asset catalog instead of running the existing icon-packaging script.

## Build Settings and Signing

All targets use:

- macOS 15.0 as the deployment target;
- Swift 6 language mode for Swift targets;
- the existing project warning and concurrency settings unless Xcode requires a target-specific exception;
- Team ID `DR8RRE2NCU` for the current Personal Team development configuration.

Debug and ordinary Release builds use automatic Apple Development signing. All executable products use the same Team ID and their target-specific identifiers.

A future paid-account release can override signing with a `Developer ID Application` identity. Notarization remains a separate operation and is unavailable to the free Personal Team.

## Makefile Interface

The `Makefile` remains the supported command-line interface and calls `xcodebuild`:

- `make build CONFIG=debug|release` builds the `VACUUM` scheme.
- `make test [FILTER=…]` runs the `VACUUMTests` test bundle or a selected test.
- `make app CONFIG=debug|release` builds and stages the signed product at `dist/VACUUM.app`.
- `make check` runs branding checks, script tests, unit tests, bundle checks, and signature verification.
- `make release` creates a Release app with an explicitly supplied signing identity and Team ID.
- `make notarize` submits the staged paid-account release through the existing notarization workflow.
- `make system-test` runs the opt-in installed-service test harness with the new identifiers.

Build products and Derived Data stay under repository-local ignored directories so terminal and Xcode builds do not pollute source control.

Scripts that remain useful are adapted to Xcode products. Scripts made obsolete by Xcode-native bundle assembly are removed only with their corresponding tests and Makefile references.

## Testing Strategy

The existing Swift Testing files become members of `VACUUMTests` and continue testing `VACUUMShared` through `@testable import`. Template tests and template UI tests are removed because they do not exercise VACUUM behavior.

Migration work proceeds through contract checks that first fail against the template project, then pass as targets and bundle phases are added. Checks cover:

- required target and scheme names;
- deployment target and Swift language mode;
- dependency relationships;
- application and helper identifiers;
- final helper and service-plist paths;
- explicit Info.plist values;
- compiled app-icon presence;
- consistent Team ID and signing identifiers;
- absence of template products and legacy `local.vacuum.*` identifiers;
- Makefile orchestration through `xcodebuild`.

The broad verification sequence is:

1. run focused project and bundle contract checks;
2. run `xcodebuild test` through `make test`;
3. build Debug and Release products;
4. stage `dist/VACUUM.app`;
5. inspect the bundle layout and plist values;
6. inspect every executable signature;
7. run `codesign --verify --deep --strict`;
8. run all `make check` checks;
9. perform the documented installed-system test manually on a disposable NFS export.

## Error Handling and Safety

The migration preserves the old Git working tree until the consolidated project passes automated verification. The unversioned Xcode template is incorporated without replacing committed application sources blindly.

The final directory relocation occurs only after source, tests, packaging resources, and Git metadata are accounted for. If relocation or verification fails, the existing `nfs-automount` repository remains the recovery source.

Cleanup and installation remain documented and user-operated because they affect system services, preferences, `/Applications`, and root-owned application data.

## Completion Criteria

The migration is complete when:

- `VACUUM.xcodeproj` is the only build graph;
- `Package.swift` and template sources are absent;
- the Swift Testing suite passes through `xcodebuild test`;
- all application and helper targets build in Debug and Release;
- the staged application contains the required helpers and service plists;
- all identifiers use `com.github.letsrokk.vacuum.*`;
- all executable signatures use the expected identifiers and one Team ID;
- strict deep code-signature verification passes;
- the system-test harness uses the new launchd labels;
- Git history and `origin` are intact under `/Users/rokk/projects/github/utils/vacuum`;
- `/Users/rokk/projects/github/utils/nfs-automount` no longer remains as a second working project.
