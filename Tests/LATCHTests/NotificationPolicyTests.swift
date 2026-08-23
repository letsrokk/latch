import Foundation
import Testing
@testable import LATCHShared

@Suite("Notification policy")
struct NotificationPolicyTests {
    @Test func failedClosedProducesUrgentFailure() {
        #expect(NotificationPolicy.event(previous: .healthy, current: .failedClosed, unavailableSince: nil, now: Date()) == .recoveryFailed)
    }

    @Test func recoveringToHealthyProducesRecoverySuccess() {
        #expect(NotificationPolicy.event(previous: .recovering, current: .healthy, unavailableSince: nil, now: Date()) == .recoverySucceeded)
    }

    @Test func fiveMinutesUnavailableProducesProlongedWarning() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(NotificationPolicy.event(previous: .networkUnavailable, current: .networkUnavailable, unavailableSince: now.addingTimeInterval(-301), now: now) == .prolongedUnavailable)
    }

    @Test func unchangedHealthyStateProducesNoNotification() {
        #expect(NotificationPolicy.event(previous: .healthy, current: .healthy, unavailableSince: nil, now: Date()) == nil)
    }
    @Test func eventWindowSeedsAndReplacesIDsWithoutGrowing() {
        let first = LATCHEvent(id: UUID(), date: Date(), mountID: nil, state: nil, code: .none, detail: "first")
        let second = LATCHEvent(id: UUID(), date: Date(), mountID: nil, state: nil, code: .none, detail: "second")
        let previous = EventWindowTransition.currentIDs([first])

        #expect(EventWindowTransition.newEventIDs(previous: previous, current: [first, second]) == [second.id])
        #expect(EventWindowTransition.currentIDs([second]) == [second.id])
    }
}
