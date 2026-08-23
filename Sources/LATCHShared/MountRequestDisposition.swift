public enum MountRequestDisposition: Sendable, Equatable {
    case mount
    case alreadyMounted
    case sourceConflict

    public static func classify(currentSource: String?, expectedSource: String) -> Self {
        guard let currentSource else { return .mount }
        return currentSource == expectedSource ? .alreadyMounted : .sourceConflict
    }
}
