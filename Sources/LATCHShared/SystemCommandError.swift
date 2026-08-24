import Foundation

public struct SystemCommandError: Error, Sendable, Equatable, LocalizedError {
    public let executable: String
    public let status: Int32
    public let detail: String

    public init(executable: String, status: Int32, detail: String) {
        self.executable = executable
        self.status = status
        self.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var errorDescription: String? {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        guard !detail.isEmpty else { return "\(name) failed with exit status \(status)." }
        return "\(name) failed with exit status \(status): \(detail)"
    }
}

public enum TelemetryErrorPresentation {
    public static func publicSummary(for error: Error) -> String {
        if let commandError = error as? SystemCommandError {
            let name = URL(fileURLWithPath: commandError.executable).lastPathComponent
            return "\(name) failed with exit status \(commandError.status)."
        }
        let error = error as NSError
        return "Operation failed with error code \(error.code)."
    }
}
