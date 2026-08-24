import Foundation

public enum ApplicationStopDisposition: Sendable, Equatable {
    case succeeded
    case forceQuit
    case failed
}

public enum ApplicationTerminationPolicy {
    public static func matches(configuredURL: URL, runningURL: URL?) -> Bool {
        runningURL.map(canonical) == canonical(configuredURL)
    }

    public static func disposition(
        exitedGracefully: Bool,
        allowForceQuit: Bool,
        configuredURL: URL,
        runningURL: URL?
    ) -> ApplicationStopDisposition {
        if exitedGracefully { return .succeeded }
        guard allowForceQuit,
              matches(configuredURL: configuredURL, runningURL: runningURL) else {
            return .failed
        }
        return .forceQuit
    }

    public static func restartVerified(isRunning: Bool) -> Bool { isRunning }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
