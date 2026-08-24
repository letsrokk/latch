# Final Non-Signing Remediation Design

**Date:** 2026-08-24

## Goal

Remove every Low-or-higher finding from the current Build macOS Apps review while keeping Developer ID signing, notarization, and installed release qualification out of scope until Apple account credentials are available.

## Trust boundary

The daemon will authenticate the main app and login agent separately. Each accepted XPC connection receives a role-specific exported object:

- The main app may send typed daemon requests and subscribe to runtime updates.
- The login agent may register its anonymous callback endpoint and issue the two read-only requests used by notification delivery: current statuses and recent events.
- The login agent cannot read configuration or service internals and cannot invoke mount, recovery, Wake-on-LAN, import/export, operation-management, activity-clearing, permission, or uninstall requests.
- Calls outside the authenticated role return a bounded denial and never reach `DaemonController`.

The status broadcaster will require the main-app identity, while the registered callback endpoint will continue to require the login-agent identity. A pure role/operation policy in `LATCHShared` will make the authorization matrix directly testable.

## Configuration startup recovery

`ConfigurationStore` will distinguish a genuine first run from damaged durable state:

- No primary or backup file: start with an empty, healthy configuration.
- Valid primary: load it normally.
- Invalid primary with valid backup: load the backup, quarantine the bad primary, and report degraded persistence.
- No valid copy: quarantine every damaged copy, start with an empty fail-closed configuration, and report degraded persistence.

Quarantined configuration files retain owner-only permissions. The daemon will merge configuration and runtime-store health in `ServiceStatusSnapshot`. A later successful configuration save clears configuration degradation and records a successful write time. Empty degraded startup performs no automatic mount work but preserves damaged data for diagnosis or manual recovery.

## Privacy and accessibility

Diagnostic export will redact configured NFS export paths and the export portion of external NFS sources. Tests will assert that neither raw value appears in exported JSON.

The notification delay stepper will bind to minutes rather than raw seconds and expose an explicit minute-valued accessibility string. Stored preferences remain seconds for compatibility.

## Visible hierarchy

The Overview destination will identify itself with an `Overview` page header before its Managed Mounts and Recent Activity sections. Sparse `Table` views will disable alternating row backgrounds so unused space no longer resembles loading placeholders. Native macOS table semantics, sorting, keyboard behavior, and columns remain unchanged.

## Verification

Each behavioral fix starts with a focused failing test. Final verification includes the complete Xcode suite, Xcode static analysis, script and packaging contracts, an unsigned universal Release build, architecture and coverage-symbol inspection, live preview screenshots, accessibility-tree inspection, and repeated source review. Developer ID identity, notarization, and installed-system release qualification are explicitly excluded.
