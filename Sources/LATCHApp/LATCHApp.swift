import SwiftUI
import AppKit

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
    }
}
