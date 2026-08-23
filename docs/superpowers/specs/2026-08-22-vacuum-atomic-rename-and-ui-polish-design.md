# VACUUM Atomic Rename and UI Polish Design

## Summary

Complete the early-development rebrand by removing obsolete Guardian and NFS Mount Guardian naming from the product, build targets, source layout, native symbols, XPC interfaces, tests, packaging, and runtime identity metadata. Apply the requested folder-picker, monitoring terminology, Support labels, and timing-control improvements in the same coordinated change.

This is an intentionally breaking internal cleanup. VACUUM does not retain compatibility aliases or migration paths for unreleased Guardian identities.

## Goals

- Use VACUUM consistently in user-facing copy and internal code.
- Rename every Swift package target, source directory, test target, executable, and module import from `Guardian*` to `VACUUM*`.
- Rename Guardian-prefixed Swift domain types, XPC protocols, request clients, presentation types, and error/action/event models.
- Rename the native C module, files, header guards, and `guardian_*` symbols to VACUUM equivalents.
- Remove obsolete NFSMountGuardian preference and application-support migration code.
- Improve the mount-folder picker so reopening it starts at the most recently selected folder.
- Present monitoring and recovery timing values with the same visible numeric-field and stepper treatment as notification timing.
- Rebuild and verify the packaged app without leaving the test app running.

## Non-goals

- Change NFS mounting, monitoring, recovery, retry, Wake-on-LAN, discovery, or configuration-portability behavior.
- Change the active `local.vacuum.*` service identifiers, `/Library/Application Support/VACUUM` path, `.vacuumconfig` extension, or configuration schema. These already use the final identity.
- Preserve compatibility with unreleased `local.nfsmountguardian` preferences or `/Library/Application Support/NFSMountGuardian` data.
- Rename generic domain concepts such as `MountDefinition`, `MountStatus`, or `RecoveryCoordinator` when they do not contain obsolete branding.

## Atomic Internal Rename

Rename package products and targets as follows:

| Current | Final |
| --- | --- |
| `GuardianShared` | `VACUUMShared` |
| `GuardianNative` | `VACUUMNative` |
| `GuardianApp` | `VACUUMApp` |
| `GuardianDaemon` | `VACUUMDaemon` |
| `GuardianAgent` | `VACUUMAgent` |
| `GuardianProbe` | `VACUUMProbe` |
| `GuardianSharedTests` | `VACUUMSharedTests` |

Move the matching source and test directories so SwiftPM target discovery remains conventional. Update all module imports, package dependencies, build scripts, and executable-copy paths together.

Rename Guardian-prefixed Swift symbols to VACUUM-prefixed symbols, including configuration, events, errors, actions, requests, responses, XPC protocols, daemon clients, overview/setup/menu presentation models, preview fixtures, notification events, and app views. Rename source filenames when the filename itself contains Guardian terminology.

Rename `GuardianNative.c`, `GuardianNative.h`, their header guard, and every exported `guardian_*` function to `VACUUMNative.c`, `VACUUMNative.h`, and `vacuum_*`. Update all Swift call sites.

Rename the packaged Info.plist key `GuardianTeamIdentifier` to `VACUUMTeamIdentifier` and update the build script, signing script, and runtime lookup in one change.

Remove `legacyPreferenceSuite`, `legacyApplicationSupportDirectory`, and NFSMountGuardian migration behavior. Tests will exercise only active VACUUM identities after the rename.

## User-facing Terminology

Use monitoring language throughout the current UI:

- `Protection Setup` becomes `Monitoring Setup`.
- `Protection needs setup` becomes `Monitoring needs setup`.
- Setup explanations describe monitoring and automatic recovery, not protection.
- User-facing Guardian or NFS Mount Guardian references become VACUUM.

Internal and user-facing searches must finish with no obsolete branding in active source, tests, scripts, or packaging. Historical design and implementation documents may retain the old project name because they describe prior decisions; they are not runtime product surfaces.

## Folder Picker

The mount-folder panel message becomes `Choose an existing empty folder.`

When no folder has been selected in the current mount-editor session, the panel opens at the user home directory. After a successful selection, reopening the panel starts at that selected folder. Cancelling the panel does not change the remembered location. The existing validation still requires an existing empty folder in an allowed root and never creates a directory automatically.

Keep the remembered picker location in the mount editor's transient draft state. Do not persist it as application configuration.

## Settings Labels

In Settings > Support:

- `Export Redacted Diagnostics…` becomes `Export Diagnostics`.
- `Export Configuration…` becomes `Export Configuration`.
- `Import Configuration…` becomes `Import Configuration`.

The diagnostics remain redacted; only the shorter action label changes.

## Monitoring and Recovery Timing Controls

Replace label-style steppers with explicit horizontal rows modeled after the notification-delay control:

- `Probe interval: <value> <stepper> seconds`
- `Probe timeout: <value> <stepper> seconds`
- `Recovery cooldown: <value> <stepper> minutes`

Each value uses monospaced digits, a visible text-field-like background, a single outline, and enough fixed width to avoid layout movement. The stepper remains immediately beside the value. Existing ranges and increments remain authoritative:

- Probe interval: 10–3600 seconds, step 10.
- Probe timeout: 1–30 seconds, step 1.
- Recovery cooldown: 1–1440 minutes, stored as 60–86400 seconds, step 1 minute.

The existing validation that probe timeout must be shorter than probe interval remains unchanged.

## Testing

Add or update tests before production changes for:

- Final VACUUM module, type, protocol, identity-key, and native-symbol naming contracts.
- Absence of obsolete Guardian/NFSMountGuardian runtime and packaging strings.
- Folder-picker initial-directory selection: home before selection, chosen folder afterward, unchanged after cancellation.
- Final user-facing monitoring and Support labels.
- Timing row presentation, units, ranges, and storage conversion for recovery cooldown.

Run focused tests after each slice. Finish with the complete Swift test suite, an ad-hoc app build, strict code-signature verification, packaged-content inspection, and a process check that confirms the rebuilt test app is closed.

## Risks and Controls

- **Incomplete rename:** A stale module import, protocol name, C symbol, or build-script binary name can break the build or packaged app. Use exhaustive searches before and after the rename, then build every target.
- **XPC mismatch:** Renaming only one side of a protocol would disconnect the app, agent, and daemon. Rename request/response/protocol symbols and all `NSXPCInterface` call sites as one slice, then run XPC tests.
- **Packaging mismatch:** SwiftPM binary names and copied helper names differ intentionally: targets become `VACUUM*`, while packaged helper executables already use `VACUUM*`. Verify every packaged path and service plist.
- **Accidental data-format change:** Swift type names do not affect synthesized Codable keys. Keep model properties, enum raw values, configuration schema version, and portable file format unchanged.
- **Unreleased migration removal:** Existing NFSMountGuardian development data will no longer migrate. This is explicitly accepted for early development; active VACUUM data remains in place.

## Acceptance Criteria

- The current folder is reused as the next folder-picker starting location within the editor session.
- All requested labels and timing layouts match this design.
- Active source, tests, scripts, and packaging contain no obsolete Guardian/NFSMountGuardian branding except where a historical document is intentionally excluded.
- Every SwiftPM target and source/test directory uses VACUUM naming.
- Swift, XPC, native C, packaging, and signing names agree.
- Configuration schema and mount behavior remain unchanged.
- The full test suite and ad-hoc app build pass.
- Strict signature verification passes for `dist/VACUUM.app`.
- No rebuilt VACUUM test app process remains running at handoff.
