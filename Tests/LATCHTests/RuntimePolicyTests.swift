import Testing
@testable import LATCHShared

@Suite("Application runtime policies")
struct RuntimePolicyTests {
    @Test func runtimeSnapshotsApplyOnlyWhenTheirRevisionAdvances() {
        #expect(RuntimeSnapshotApplicationPolicy.shouldApply(candidateRevision: 1, after: nil))
        #expect(RuntimeSnapshotApplicationPolicy.shouldApply(candidateRevision: 9, after: 8))
        #expect(!RuntimeSnapshotApplicationPolicy.shouldApply(candidateRevision: 9, after: 9))
        #expect(!RuntimeSnapshotApplicationPolicy.shouldApply(candidateRevision: 8, after: 9))
    }
}
