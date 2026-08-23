public enum MountRevealPolicy {
    public static func isAvailable(observedSource: String?, expectedSource: String?) -> Bool {
        guard let expectedSource, !expectedSource.isEmpty else { return false }
        return observedSource == expectedSource
    }
}
