import Foundation

public enum DockerCommandExecutionError: Error, Sendable, Equatable {
    case missingRuntime
    case timedOut
    case failed(String)
}

public struct DockerCommandExecutor: Sendable {
    public typealias ProcessRunner = @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String],
        _ timeout: Duration
    ) async throws -> BoundedProcessResult

    public static let candidatePaths = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
    ]
    public static let restrictedPath = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    private let candidates: [String]
    private let isExecutable: @Sendable (String) -> Bool
    private let processRunner: ProcessRunner

    public init() {
        candidates = Self.candidatePaths
        isExecutable = { FileManager.default.isExecutableFile(atPath: $0) }
        processRunner = { executable, arguments, environment, timeout in
            try await BoundedProcessRunner.run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: timeout
            )
        }
    }

    public init(
        candidatePaths: [String],
        isExecutable: @escaping @Sendable (String) -> Bool,
        processRunner: @escaping ProcessRunner
    ) {
        candidates = candidatePaths
        self.isExecutable = isExecutable
        self.processRunner = processRunner
    }

    public func execute(
        arguments: [String],
        dependency: DockerContainerDependency,
        timeout: Duration
    ) async throws -> String {
        guard let executable = candidates.first(where: isExecutable) else {
            throw DockerCommandExecutionError.missingRuntime
        }
        var environment = [
            "DOCKER_HOST": "unix://\(dependency.dockerSocketPath)",
            "PATH": Self.restrictedPath,
        ]
        if let composeFilePath = dependency.composeFilePath {
            environment["COMPOSE_FILE"] = composeFilePath
        }
        do {
            let result = try await processRunner(executable, arguments, environment, timeout)
            guard result.terminationStatus == 0 else {
                throw DockerCommandExecutionError.failed(
                    result.standardError.isEmpty ? "The Docker command failed." : result.standardError
                )
            }
            return result.standardOutput
        } catch BoundedProcessError.timedOut {
            throw DockerCommandExecutionError.timedOut
        }
    }
}
