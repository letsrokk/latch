import Foundation
import Testing
@testable import LATCHShared

@Suite("Mount monitoring schedules")
struct MonitoringScheduleTests {
    @Test func monitoringLoopSleepsUntilTheNextEnabledMountCheck() {
        let now = Date(timeIntervalSince1970: 1_000)
        let enabled = MountDefinition(
            displayName: "Media",
            host: "nas.local",
            exportPath: "/media",
            mountPoint: "/Volumes/Media",
            probeIntervalSeconds: 8
        )
        var disabled = enabled
        disabled.id = UUID()
        disabled.enabled = false

        #expect(MonitoringLoopSchedule.delay(
            definitions: [enabled],
            lastChecks: [enabled.id: now.addingTimeInterval(-3)],
            mountedAt: [:],
            now: now,
            mountGrace: 3
        ) == 5)
        #expect(MonitoringLoopSchedule.delay(
            definitions: [enabled],
            lastChecks: [:],
            mountedAt: [enabled.id: now.addingTimeInterval(-1)],
            now: now,
            mountGrace: 3
        ) == 2)
        #expect(MonitoringLoopSchedule.delay(
            definitions: [enabled],
            lastChecks: [enabled.id: now.addingTimeInterval(-20)],
            mountedAt: [:],
            now: now,
            mountGrace: 3
        ) == 1)
        #expect(MonitoringLoopSchedule.delay(
            definitions: [disabled],
            lastChecks: [:],
            mountedAt: [:],
            now: now,
            mountGrace: 3
        ) == 60)
    }

    @Test func firstHealthCheckWaitsForMountGracePeriod() {
        let mountedAt = Date(timeIntervalSince1970: 100)

        #expect(!MountCheckSchedule.isDue(lastCheck: nil, mountedAt: mountedAt, now: mountedAt.addingTimeInterval(2), interval: 60, mountGrace: 3))
        #expect(MountCheckSchedule.isDue(lastCheck: nil, mountedAt: mountedAt, now: mountedAt.addingTimeInterval(3), interval: 60, mountGrace: 3))
        #expect(!MountCheckSchedule.isDue(lastCheck: mountedAt, mountedAt: nil, now: mountedAt.addingTimeInterval(59), interval: 60, mountGrace: 3))
        #expect(MountCheckSchedule.isDue(lastCheck: mountedAt, mountedAt: nil, now: mountedAt.addingTimeInterval(60), interval: 60, mountGrace: 3))
    }
}
