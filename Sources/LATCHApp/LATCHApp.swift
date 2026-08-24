import SwiftUI
import AppKit
import LATCHShared

@main
struct LATCHApp: App {
    @StateObject private var model = AppModel()
    private let replacementMarkerPath = ProcessInfo.processInfo.arguments
        .first(where: { $0.hasPrefix("--prepare-for-app-replacement=") })?
        .split(separator: "=", maxSplits: 1)
        .last
        .map(String.init)
    private let opensMainWindow = ProcessInfo.processInfo.arguments.contains("--visual-preview")
        || ProcessInfo.processInfo.arguments.contains("--open-window")

    var body: some Scene {
        MenuBarExtra {
            LATCHMenu()
                .environmentObject(model)
                .onAppear { model.start() }
        } label: {
            Label("LATCH", systemImage: model.aggregateSymbol)
                .task {
                    if let replacementMarkerPath {
                        await model.prepareForAppReplacement(markerPath: replacementMarkerPath)
                        NSApplication.shared.terminate(nil)
                    } else {
                        model.start()
                    }
                }
        }
        .menuBarExtraStyle(.window)

        Window("LATCH", id: "latch-main") {
            SettingsView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear {
                    model.start()
                    model.mainWindowDidAppear()
                    NSApplication.shared.setActivationPolicy(.regular)
#if DEBUG
                    Task { await model.runDebugActionIfRequested() }
#endif
                    if opensMainWindow { NSApplication.shared.activate(ignoringOtherApps: true) }
                }
                .onDisappear {
                    model.mainWindowDidClose()
                    NSApplication.shared.setActivationPolicy(.accessory)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await model.applicationDidBecomeActive() }
                }
        }
        .defaultSize(width: 1040, height: 680)
        .defaultLaunchBehavior(opensMainWindow ? .presented : .suppressed)
        .commands {
            LATCHCommands(model: model)
        }

        Settings {
            LATCHPreferencesView()
                .environmentObject(model)
                .onAppear { model.start() }
        }
    }
}

private struct LATCHCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Navigate") {
            navigationButton("Overview", destination: .overview, key: "1")
            navigationButton("Managed Mounts", destination: .managed, key: "2")
            navigationButton("Servers", destination: .servers, key: "3")
            navigationButton("External Mounts", destination: .external, key: "4")
            navigationButton("Activity", destination: .activity, key: "5")
        }
        CommandGroup(after: .toolbar) {
            Button("Refresh Status") { Task { await model.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
        }
    }

    private func navigationButton(
        _ title: String,
        destination: LATCHMainDestination,
        key: KeyEquivalent
    ) -> some View {
        Button(title) {
            model.mainDestination = destination
            openWindow(id: "latch-main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(key, modifiers: .command)
    }
}
