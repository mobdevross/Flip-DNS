import DNSCore
import XCTest

private final class MemoryStorage: BypassStorage {
    var saved: TimedBypass?
    func load() -> TimedBypass? { saved }
    func save(_ bypass: TimedBypass?) { saved = bypass }
}

private final class FakeBackend: DNSBackend {
    var services = [DNSService(id: "wifi", name: "Wi-Fi", device: "en0", kind: .wifi)]
    var changes: [DNSChange] = []
    var failNextChange = false
    var failReads = false
    var beforeChange: (() -> Void)?

    func readServices() async throws -> [DNSService] {
        if failReads { throw DNSError.operation("Read failed") }
        return services
    }

    func perform(_ change: DNSChange) async throws -> DNSChangeResult {
        changes.append(change)
        beforeChange?()
        if failNextChange {
            failNextChange = false
            throw DNSError.operation("Authorization cancelled")
        }
        let targets = Set(change.targets(in: services).map(\.id))
        services = services.map {
            DNSService(id: $0.id, name: $0.name, device: $0.device, kind: $0.kind,
                       isEnabled: $0.isEnabled, servers: targets.contains($0.id) ? change.profile.servers : $0.servers)
        }
        let skipped: Set<String>
        if case let .restoreTimedBypass(ids) = change { skipped = ids.subtracting(targets) }
        else { skipped = [] }
        return DNSChangeResult(services: services, targetedServiceIDs: targets, skippedServiceIDs: skipped)
    }
}

final class TimerTests: XCTestCase {
    @MainActor
    func testDeadlineStartsAfterAuthorizationAndRestoresOnlyWhenDue() async {
        let backend = FakeBackend()
        let storage = MemoryStorage()
        var now = Date(timeIntervalSince1970: 1_000)
        let model = SwitcherModel(backend: backend, storage: storage, now: { now })
        backend.beforeChange = { now = Date(timeIntervalSince1970: 1_030) }
        let success = await model.choose(.publicDNS, minutes: 5)
        XCTAssertTrue(success)
        XCTAssertEqual(storage.saved?.deadline, Date(timeIntervalSince1970: 1_330))
        backend.beforeChange = nil
        now = Date(timeIntervalSince1970: 1_329)
        await model.checkDeadline()
        XCTAssertEqual(backend.changes.count, 1)
        now = Date(timeIntervalSince1970: 1_330)
        await model.checkDeadline()
        XCTAssertEqual(backend.changes.last, .restoreTimedBypass(serviceIDs: ["wifi"]))
        XCTAssertEqual(model.mode, .automatic)
        XCTAssertNil(model.bypass)
        XCTAssertNil(storage.saved)
    }

    @MainActor
    func testExpiredAuthorizationShowsPendingAndDoesNotPromptRepeatedly() async {
        let backend = FakeBackend()
        let storage = MemoryStorage()
        var now = Date(timeIntervalSince1970: 1_000)
        let model = SwitcherModel(backend: backend, storage: storage, now: { now })
        await model.choose(.publicDNS, minutes: 5)
        backend.failNextChange = true
        now = now.addingTimeInterval(301)
        await model.checkDeadline()
        XCTAssertEqual(model.bypass?.restorePending, true)
        XCTAssertEqual(storage.saved?.restorePending, true)
        XCTAssertEqual(model.mode, .publicDNS)
        XCTAssertNotNil(model.errorMessage)
        await model.checkDeadline()
        await model.checkDeadline()
        XCTAssertEqual(backend.changes.count, 2)

        let relaunched = SwitcherModel(backend: backend, storage: storage, now: { now })
        await relaunched.checkDeadline()
        XCTAssertEqual(backend.changes.count, 2)
        let restored = await relaunched.restoreTimedBypass()
        XCTAssertTrue(restored)
        XCTAssertEqual(relaunched.mode, .automatic)
        XCTAssertNil(storage.saved)
    }

    @MainActor
    func testOverdueTimerRestoresAfterWakeOrRelaunch() async {
        let backend = FakeBackend()
        let storage = MemoryStorage()
        var now = Date(timeIntervalSince1970: 1_000)
        let original = SwitcherModel(backend: backend, storage: storage, now: { now })
        await original.choose(.publicDNS, minutes: 15)
        now = now.addingTimeInterval(3_600)
        let relaunched = SwitcherModel(backend: backend, storage: storage, now: { now })
        await relaunched.checkDeadline()
        XCTAssertNil(relaunched.bypass)
        XCTAssertEqual(relaunched.mode, .automatic)
    }

    @MainActor
    func testSuccessfulManualSelectionCancelsTimer() async {
        let backend = FakeBackend()
        let storage = MemoryStorage()
        var now = Date(timeIntervalSince1970: 1_000)
        let model = SwitcherModel(backend: backend, storage: storage, now: { now })
        await model.choose(.publicDNS, minutes: 5)
        await model.choose(.publicDNS)
        XCTAssertNil(model.bypass)
        now = now.addingTimeInterval(1_000)
        await model.checkDeadline()
        XCTAssertEqual(backend.changes.count, 2)
        XCTAssertEqual(model.mode, .publicDNS)
    }

    @MainActor
    func testFailedManualSelectionKeepsPreviousTimer() async {
        let backend = FakeBackend()
        let storage = MemoryStorage()
        let model = SwitcherModel(backend: backend, storage: storage)
        await model.choose(.publicDNS, minutes: 60)
        let original = model.bypass
        backend.failNextChange = true
        let changed = await model.choose(.automatic)
        XCTAssertFalse(changed)
        XCTAssertEqual(model.bypass, original)
        XCTAssertEqual(storage.saved, original)
    }

    @MainActor
    func testExternalEditsSurviveTimerExpiry() async {
        let backend = FakeBackend()
        let storage = MemoryStorage()
        var now = Date(timeIntervalSince1970: 1_000)
        let model = SwitcherModel(backend: backend, storage: storage, now: { now })
        await model.choose(.publicDNS, minutes: 5)
        backend.services = [DNSService(id: "wifi", name: "Wi-Fi", device: "en0", kind: .wifi, servers: ["10.0.0.53"])]
        now = now.addingTimeInterval(301)
        await model.checkDeadline()
        XCTAssertNil(model.bypass)
        XCTAssertEqual(model.mode, .custom)
        XCTAssertEqual(model.services.first?.servers, ["10.0.0.53"])
        XCTAssertNotNil(model.information)
    }

    @MainActor
    func testAbandoningTimerLeavesDNSAlone() async {
        let backend = FakeBackend()
        let storage = MemoryStorage()
        let model = SwitcherModel(backend: backend, storage: storage)
        await model.choose(.publicDNS, minutes: 5)
        model.abandonTimer()
        XCTAssertEqual(model.mode, .publicDNS)
        XCTAssertNil(storage.saved)
        XCTAssertEqual(backend.changes.count, 1)
    }

    @MainActor
    func testReadFailureDisablesConfigurationState() async {
        let backend = FakeBackend()
        let model = SwitcherModel(backend: backend, storage: MemoryStorage())
        await model.refresh()
        XCTAssertEqual(model.mode, .automatic)
        backend.failReads = true
        await model.refresh()
        XCTAssertEqual(model.mode, .unavailable)
        XCTAssertFalse(model.isReadable)
        backend.failReads = false
        await model.refresh()
        XCTAssertEqual(model.mode, .automatic)
        XCTAssertNil(model.errorMessage)
    }

    func testBypassPersistenceRoundTripRetainsPendingStateAndDeadline() throws {
        let value = TimedBypass(deadline: Date(timeIntervalSince1970: 123_456),
                                serviceIDs: ["wifi", "ethernet"], restorePending: true)
        let decoded = try JSONDecoder().decode(TimedBypass.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
    }
}
