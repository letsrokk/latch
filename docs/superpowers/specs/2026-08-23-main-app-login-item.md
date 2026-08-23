# Main-App Login Item Design

VACUUM must show its menu-bar icon automatically after the user logs in. macOS must launch the main application through `SMAppService.mainApp`; the user-session agent remains responsible for XPC coordination and post-mount actions, but it must not launch the application with `NSWorkspace`.

The existing combined Monitoring Setup action registers and removes three services as one logical unit:

1. the privileged daemon;
2. the user-session login agent;
3. the VACUUM main application login item.

The setup UI reports Ready only when all three registrations are enabled and both executable services are online. Any registration that requires approval keeps the existing Login Items guidance active. Removing services unregisters all three. App replacement unregisters all three before replacing the bundle.

The main app remains an `LSUIElement`, so launch at login shows the menu-bar extra without activating or opening the main window. The agent contains no fallback application-launch loop and performs no retries.

Acceptance criteria:

- A combined setup registers `SMAppService.mainApp` in addition to the daemon and agent.
- Approval polling includes the main-app login item.
- Ready requires all three registrations.
- Combined removal and app-replacement preparation unregister all three registrations.
- The agent no longer derives or opens the containing app.
- Existing daemon/agent repair behavior remains intact and repairs all three registrations after an app replacement.
- Focused service-management tests, the complete Swift suite, and an ad-hoc app build pass.
- Verification leaves no staged VACUUM app process running.
