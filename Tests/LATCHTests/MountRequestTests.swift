import Testing
@testable import LATCHShared

@Suite("Mount request disposition")
struct MountRequestTests {
    @Test func matchingSourceIsAlreadyMounted() {
        #expect(MountRequestDisposition.classify(
            currentSource: "server.local:/volume1/Music",
            expectedSource: "server.local:/volume1/Music"
        ) == .alreadyMounted)
    }

    @Test func missingSourceCanBeMounted() {
        #expect(MountRequestDisposition.classify(
            currentSource: nil,
            expectedSource: "server.local:/volume1/Music"
        ) == .mount)
    }

    @Test func differentSourceIsAConflict() {
        #expect(MountRequestDisposition.classify(
            currentSource: "other.local:/Music",
            expectedSource: "server.local:/volume1/Music"
        ) == .sourceConflict)
    }
}
