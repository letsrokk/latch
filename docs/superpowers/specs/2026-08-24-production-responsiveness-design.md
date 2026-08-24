# Production Responsiveness Design

**Date:** 2026-08-24
**Baseline:** `cfcca89`
**Status:** Approved for implementation by the request to implement the reviewed roadmap

## Goal

Make LATCH's status and activity surfaces monotonic and prompt, prevent a faulty login agent or one slow mount from stopping monitoring, reduce routine background writes, report persistence failures honestly, and leave the macOS UI easier to maintain and verify.

## Runtime State Stream

The daemon publishes one versioned `LATCHRuntimeSnapshot` containing a monotonically increasing revision, all current mount statuses, and the newest 100 activity events. Status or event changes increment the revision and publish a complete snapshot. The subscription handshake immediately publishes the current snapshot, closing the gap between fallback polling and live delivery.

The app tracks the highest applied revision. It ignores older live snapshots and older fallback responses. Legacy status-only and event-only sink payloads remain decodable during the transition, but they cannot overwrite a revisioned snapshot after the app has accepted one.

## Login-Agent Deadlines

Every daemon-to-agent request has an end-to-end deadline. Probe deadlines derive from the configured probe timeout with a small transport allowance. Application dependency operations use their configured timeout plus bounded cleanup allowance. Reveal and post-mount actions use fixed short deadlines. A timeout invalidates the current connection so the agent can re-register cleanly.

Timeout behavior remains fail-safe:

- A probe timeout becomes an unavailable or timed-out probe result and never authorizes recovery.
- A dependency timeout enters the existing uncertain-side-effect recovery path and can fail closed.
- A post-mount timeout leaves its durable delivery pending.
- A reveal timeout fails only that foreground operation.

## Monitoring Scheduling

Due checks run independently with a concurrency limit of two. Per-mount generation tokens still prevent conflicting automatic and manual work. Recovery remains globally serialized by `RecoveryCoordinator`.

Each sweep memoizes NFS reachability per hostname. Multiple mounts on one NAS share the same reachability result for that sweep. The implementation must not start an unbounded task per configured mount.

## Persistence

Critical state transitions remain synchronous and durable: monitoring pause, retry scheduling, recovery cooldown, pending post-mount delivery, acknowledgement, configuration changes, and event clearing.

Routine status observations are coalesced into one runtime-state write at the end of a due-check batch, or a bounded debounce when produced outside a batch. No-op retry updates do not write. A daemon shutdown or restart may lose only the latest routine probe timestamp, never a recovery or ownership decision.

Clearing activity returns success only after the durable state write succeeds. The app clears its local list only after that success response.

## macOS UI Structure

The main scene root is named `MainWindowView`, not `SettingsView`. Sidebar and destination composition move into focused view types. The selected destination uses scene storage so window restoration does not turn transient modal state into an application-global preference.

AppKit remains limited to capabilities SwiftUI does not express cleanly, such as validating an existing mount directory and controlling activation policy. Interactive controls remain separate accessibility elements; a row must not combine a button or menu into a static summary element.

## Telemetry

Unified logging records bounded, privacy-safe performance signals:

- runtime snapshot revision and detected gaps;
- health-sweep start, duration, and due-mount count;
- agent-request timeout category;
- coalesced persistence duration and failure;
- per-host reachability duration without logging raw hostnames.

Telemetry must not log mount paths, server names, configuration payloads, or user document contents.

## Verification Contract

Production readiness requires:

1. Deterministic tests prove stale fallback state cannot overwrite a newer live revision.
2. A never-replying agent reaches its deadline and does not prevent another mount from completing a check.
3. Healthy multi-mount sweeps perform a bounded number of runtime writes.
4. Activity clearing preserves UI and daemon state and returns a failure when persistence fails.
5. Existing operation lifecycle, recovery, XPC authentication, packaging, and release contracts remain green.
6. The Debug build, full test suite, Xcode analysis, bundle validation, and release workflow contracts pass.
7. A final read-only Build macOS Apps review finds no unresolved material source defect.

Developer ID notarization and destructive installed NFS recovery remain external release gates when credentials or a disposable export are unavailable. They must stay documented and may not be represented as completed without direct evidence.
