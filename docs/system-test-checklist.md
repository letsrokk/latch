# Signed macOS System Test Checklist

Run these checks on a disposable NFS export before enabling recovery for production media mounts. Build the app with the native `LATCH.xcodeproj` through `make release`, and use a Developer ID Application identity for installed-service testing. Development builds signed by a free Personal Team are suitable for local app testing but do not replace this signed service-context check.

1. Build with a Developer ID Application identity and notarize the bundle.
2. Copy `LATCH.app` to `/Applications` before registration so its path and code identity remain stable.
3. Register the LaunchAgent and LaunchDaemon from app Settings, approve both in Login Items, then confirm `launchctl print system/com.github.letsrokk.latch.daemon` and `launchctl print gui/$(id -u)/com.github.letsrokk.latch.agent` show running services.
4. Quit the menu UI. Confirm the daemon remains running and produces status transitions without one log entry per healthy polling interval.
5. Mount a disposable app-managed NFS export and select **Verify Network Volumes**. In the TCC log, confirm the responsible code is LATCH or its signed helper, never `/bin/sh`, `/usr/bin/find`, or Terminal.
6. Confirm both native probe operations succeed from the registered daemon context. Do not enable automatic recovery if this gate fails.
7. Interrupt network access briefly. Confirm the state becomes `networkUnavailable` or `probeTimedOut`, no unmount occurs, and reconnection returns the mount to `healthy`.
8. Produce a controlled numeric `ESTALE` on the disposable export. Confirm only that mount enters recovery and that its configured dependencies stop in order.
9. Confirm the daemon force-unmounts only the exact configured mountpoint, mounts with the deterministic typed option list, verifies the exact source, runs a fresh probe, and restarts previously running dependencies in reverse order.
10. Force remount verification to fail. Confirm the state becomes `failedClosed`, stopped dependencies remain stopped, and the UI presents an urgent actionable error.
11. Configure a macOS application dependency with force quit disabled, then enabled. Confirm force quit occurs only when Launch Services resolves a relaunch target with the configured bundle identifier.
12. Confirm external NFS mounts appear only in External Mounts and cannot be imported, edited, probed, recovered, or included in aggregate health.
13. Reboot and log out/in. Confirm service authorization, configuration, typed options, managed mounts, and last status survive.
14. Run uninstall with and without app-owned unmount. Confirm it removes only LATCH monitoring services and state while preserving external mounts, `fstab`, autofs, Docker configuration, and unified logs.
15. Start a long-running manual mount or recovery action, confirm the UI reports accepted/running state, then cancel it. Verify the operation reaches `cancelled`, no later success is reported, and the mount status refreshes to the daemon's actual state.

The repeatable installed-system workflow is available through the opt-in harness:

```text
make system-test STEP=preflight SIGNING_IDENTITY="Developer ID Application: …" TEAM_ID="…" SYSTEM_TEST_ACK=YES
make system-test STEP=install SYSTEM_TEST_ACK=YES
make system-test STEP=approval SYSTEM_TEST_ACK=YES
make system-test STEP=replace SYSTEM_TEST_ACK=YES
make system-test STEP=prepare-login SYSTEM_TEST_ACK=YES
make system-test STEP=verify-login SYSTEM_TEST_ACK=YES
make system-test STEP=restore SYSTEM_TEST_ACK=YES
```

Each run stores its manifest and backup under `.build/system-tests/<run-id>/`. The harness never resets Background Task Management, changes unrelated Login Items, removes `/Library/Application Support/LATCH`, or touches mounted volumes. Follow the README's manual cleanup section separately when replacing a pre-migration installation.
