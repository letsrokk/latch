import Foundation

public enum PostMountActionValidationError: Error, Sendable, Equatable {
    case invalidBundleIdentifier
    case invalidApplicationHint
    case invalidRelativePath
    case relativePathEscapesMount
    case applicationBundleMismatch
}

public enum PostMountActionValidator {
    public static func validate(_ actions: [PostMountAction]) throws {
        for action in actions { try validate(action) }
    }

    public static func validate(_ action: PostMountAction) throws {
        switch action {
        case .revealInFinder:
            return
        case .openApplication(let bundleIdentifier, let applicationURL):
            guard isBundleIdentifier(bundleIdentifier) else { throw PostMountActionValidationError.invalidBundleIdentifier }
            if let applicationURL {
                let url = URL(fileURLWithPath: applicationURL)
                guard applicationURL.hasPrefix("/"), url.pathExtension.lowercased() == "app" else {
                    throw PostMountActionValidationError.invalidApplicationHint
                }
            }
        case .openRelativePath(let path):
            try validateRelativePath(path)
        }
    }

    static func validateRelativePath(_ path: String) throws {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !path.hasPrefix("/") else {
            throw PostMountActionValidationError.invalidRelativePath
        }
        guard !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw PostMountActionValidationError.invalidRelativePath
        }
    }

    private static func isBundleIdentifier(_ identifier: String) -> Bool {
        let components = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}

public enum PostMountPathResolver {
    public static func resolve(relativePath: String, beneath mountRoot: URL) throws -> URL {
        try PostMountActionValidator.validate(.openRelativePath(relativePath))
        let root = mountRoot.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            throw PostMountActionValidationError.relativePathEscapesMount
        }
        return candidate
    }
}

public enum PostMountApplicationTarget {
    public static func validate(resolvedURL: URL, expectedBundleIdentifier: String, actualBundleIdentifier: String?) throws -> URL {
        guard actualBundleIdentifier == expectedBundleIdentifier else {
            throw PostMountActionValidationError.applicationBundleMismatch
        }
        return resolvedURL.standardizedFileURL
    }
}

public enum PostMountDispatchPolicy {
    public static func shouldDispatch(previousSource: String?, verifiedSource: String?) -> Bool {
        previousSource == nil && verifiedSource != nil
    }
}

public enum PostMountActionDispatchOutcome {
    public static let preservesMountState = true

    public static func activityFailures(for response: AgentResponse) -> [String] {
        switch response {
        case .succeeded:
            []
        case .postMountActionsAcknowledged(let acknowledgement):
            acknowledgement.failures
        case .postMountActionFailures(let failures):
            failures
        case .failed(let detail):
            [detail]
        default:
            ["Post-mount actions returned an unexpected agent response."]
        }
    }
}
