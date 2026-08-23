import Foundation

public enum LATCHIdentity {
    public static let name = "LATCH"
    public static let expandedName = "LAN Automount, Tracking, Connection & Health"
    public static let bundleIdentifier = "com.github.letsrokk.latch"
    public static let daemonIdentifier = "com.github.letsrokk.latch.daemon"
    public static let agentIdentifier = "com.github.letsrokk.latch.agent"
    public static let probeIdentifier = "com.github.letsrokk.latch.probe"
    public static let preferenceSuite = "com.github.letsrokk.latch.shared"
    public static let configurationTypeIdentifier = "com.github.letsrokk.latch.configuration"
    public static let applicationSupportDirectory = URL(fileURLWithPath: "/Library/Application Support/LATCH", isDirectory: true)
}
