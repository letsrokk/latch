# Production Readiness Remediation Design

## Goal

Resolve every finding from the latest Build macOS Apps review, then repeat the review and remediation cycle until the app has no material production-readiness defect.

## Operation lifecycle

The daemon owns operation admission and terminal truth. It accepts at most one active manual operation per mount, rejects a conflicting request with `mountConflict`, and retains terminal snapshots independently of whether a client remains connected. Cancellation is a request, not a terminal result: the daemon publishes `cancelled` only when work stops without a stronger safety failure. A failed-closed recovery result takes precedence and remains `failed` with its diagnostic detail.

`LATCHRequest` gains an operation-list request. The app loads daemon snapshots during refresh, resumes monitoring accepted or running operations, and polls until each operation reaches a terminal state. It never removes active state because of an arbitrary client deadline. Transient transport failures use bounded retry; terminal snapshots remain visible until the next authoritative refresh.

## Testable safety seams

Deterministic operation admission, terminal precedence, retention, and cancellation classification live in focused `LATCHShared` types. The daemon continues to own I/O and tasks, but delegates lifecycle decisions to these tested policies. A shared bounded-process runner concurrently drains output, supports timeout and task cancellation, and accepts an executable path and environment so daemon and agent command behavior can be tested with controlled local processes. Application termination decisions use a pure URL-equivalence and restart-verification policy; AppKit remains at the narrow execution boundary.

## Desktop integration

The managed-mount screen receives the same active-operation state as the menu bar UI. It disables conflicting edits and actions, exposes cancellation while allowed, and reports progress. The app adds a dedicated SwiftUI `Settings` scene for durable preferences and standard commands for navigation, refresh, and settings access.

## Release and run contracts

Release builds target `generic/platform=macOS`, explicitly disable coverage instrumentation, and must contain both `arm64` and `x86_64`. A release validator checks architecture, Developer ID Application signing, hardened runtime, nested-code signatures, and the absence of `get-task-allow` before packaging or notarization. Credential-dependent distribution remains fail-fast: no script may label a development-signed artifact as a production release.

The project-local run script stops and verifies the exact staged executable path. `.codex/environments/environment.toml` exposes that script as the Codex Run action. Script behavior remains testable without launching an unrelated installed copy of LATCH.

## Verification

Each behavior starts with a focused failing test. Final evidence includes the full Swift test suite, build-script contracts, Debug and generic Release builds, static analysis, bundle validation, launch verification, signing inspection, and a fresh Build macOS Apps review. Notarization submission is verified only when Developer ID credentials and a notary profile are available; otherwise the validator must prove that the environment fails before distribution.
