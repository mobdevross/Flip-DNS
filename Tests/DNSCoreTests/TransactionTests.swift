import DNSCore
import XCTest

private final class PreferencesDatabase {
    var descriptors: [DNSService]
    var values: [String: [String: [String]]]
    var activeValues: [String: [String: [String]]]
    var authorizedSessions = 0
    var commits = 0
    var applies = 0
    var unlocks = 0
    var failLock = false
    var failStageID: String?
    var failCommits = 0
    var failApplies = 0
    var onLock: (() -> Void)?

    init(services: [DNSService]) {
        descriptors = services
        values = Dictionary(uniqueKeysWithValues: services.map {
            ($0.id, ["ServerAddresses": $0.servers, "SearchDomains": ["home.test"]])
        })
        activeValues = values
    }

    func snapshot(_ values: [String: [String: [String]]]) -> [DNSService] {
        descriptors.map {
            DNSService(id: $0.id, name: $0.name, device: $0.device, kind: $0.kind,
                       isEnabled: $0.isEnabled, servers: values[$0.id]?["ServerAddresses"] ?? [])
        }
    }

    func transaction() -> DNSTransaction {
        DNSTransaction { authorized in
            if authorized { self.authorizedSessions += 1 }
            return FakePreferences(self)
        }
    }
}

private final class FakePreferences: DNSPreferencesSession {
    let database: PreferencesDatabase
    var staged: [String: [String: [String]]]
    var originals: [String: [String: [String]]] = [:]

    init(_ database: PreferencesDatabase) {
        self.database = database
        staged = database.values
    }

    func readServices() throws -> [DNSService] { database.snapshot(staged) }
    func lock() throws {
        if database.failLock { throw DNSError.operation("Authorization cancelled") }
        database.onLock?()
        staged = database.values
    }
    func unlock() { database.unlocks += 1 }

    func setServers(_ servers: [String], serviceID: String) throws {
        if database.failStageID == serviceID { throw DNSError.operation("Staging failed") }
        originals[serviceID] = staged[serviceID]
        if servers.isEmpty { staged[serviceID]?.removeValue(forKey: "ServerAddresses") }
        else { staged[serviceID]?["ServerAddresses"] = servers }
    }

    func commit() throws {
        database.commits += 1
        if database.failCommits > 0 {
            database.failCommits -= 1
            throw DNSError.operation("Commit failed")
        }
        database.values = staged
    }

    func apply() throws {
        database.applies += 1
        if database.failApplies > 0 {
            database.failApplies -= 1
            throw DNSError.operation("Apply failed")
        }
        database.activeValues = database.values
    }

    func stageOriginalConfigurations() throws {
        for (id, config) in originals { staged[id] = config }
    }
}

final class TransactionTests: XCTestCase {
    private func service(_ id: String, kind: DNSInterfaceKind = .wifi,
                         enabled: Bool = true, servers: [String] = []) -> DNSService {
        DNSService(id: id, name: id, device: "en0", kind: kind, isEnabled: enabled, servers: servers)
    }

    func testSwitchesEligibleServicesInOneCommitAndPreservesSearchDomains() throws {
        let database = PreferencesDatabase(services: [
            service("wifi"), service("ethernet", kind: .ethernet),
            service("vpn", kind: .excluded, servers: ["10.0.0.53"]),
            service("bridge", kind: .excluded), service("disabled", enabled: false),
        ])
        let excluded = database.values["vpn"]
        let result = try database.transaction().perform(.select(.publicDNS))
        XCTAssertEqual(result.targetedServiceIDs, ["wifi", "ethernet"])
        XCTAssertEqual(database.values["wifi"]?["ServerAddresses"], DNSProfile.publicServers)
        XCTAssertEqual(database.values["ethernet"]?["ServerAddresses"], DNSProfile.publicServers)
        XCTAssertEqual(database.values["wifi"]?["SearchDomains"], ["home.test"])
        XCTAssertEqual(database.values["vpn"], excluded)
        XCTAssertEqual(database.values["bridge"]?["ServerAddresses"], [])
        XCTAssertEqual(database.values["disabled"]?["ServerAddresses"], [])
        XCTAssertEqual(database.commits, 1)
        XCTAssertEqual(database.applies, 1)
        XCTAssertEqual(database.unlocks, 1)
        XCTAssertEqual(database.activeValues, database.values)
    }

    func testAutomaticRemovesOnlyManualServerAddresses() throws {
        let database = PreferencesDatabase(services: [service("wifi", servers: ["192.168.88.1"])])
        let result = try database.transaction().perform(.select(.automatic))
        XCTAssertNil(database.values["wifi"]?["ServerAddresses"])
        XCTAssertEqual(database.values["wifi"]?["SearchDomains"], ["home.test"])
        XCTAssertEqual(DNSMode.mode(for: result.services), .automatic)
    }

    func testSelectingExistingModeDoesNotRequestAuthorization() throws {
        let database = PreferencesDatabase(services: [service("wifi", servers: Array(DNSProfile.publicServers.reversed()))])
        let result = try database.transaction().perform(.select(.publicDNS))
        XCTAssertEqual(result.targetedServiceIDs, ["wifi"])
        XCTAssertEqual(database.authorizedSessions, 0)
        XCTAssertEqual(database.commits, 0)
    }

    func testNoEligibleServicesDoesNotRequestAuthorization() {
        let database = PreferencesDatabase(services: [service("vpn", kind: .excluded)])
        XCTAssertThrowsError(try database.transaction().perform(.select(.publicDNS)))
        XCTAssertEqual(database.authorizedSessions, 0)
        XCTAssertEqual(database.commits, 0)
    }

    func testCancelledAuthorizationPreservesAllSettings() {
        let database = PreferencesDatabase(services: [service("wifi")])
        let before = database.values
        database.failLock = true
        XCTAssertThrowsError(try database.transaction().perform(.select(.publicDNS)))
        XCTAssertEqual(database.values, before)
        XCTAssertEqual(database.commits, 0)
        XCTAssertEqual(database.unlocks, 0)
    }

    func testFailureStagingSecondServiceDoesNotCommitFirstService() {
        let database = PreferencesDatabase(services: [service("wifi"), service("ethernet", kind: .ethernet)])
        let before = database.values
        database.failStageID = "ethernet"
        XCTAssertThrowsError(try database.transaction().perform(.select(.publicDNS)))
        XCTAssertEqual(database.values, before)
        XCTAssertEqual(database.commits, 0)
        XCTAssertEqual(database.unlocks, 1)
    }

    func testCommitFailureDoesNotApplyOrChangePersistedSettings() {
        let database = PreferencesDatabase(services: [service("wifi")])
        let before = database.values
        database.failCommits = 1
        XCTAssertThrowsError(try database.transaction().perform(.select(.publicDNS)))
        XCTAssertEqual(database.values, before)
        XCTAssertEqual(database.applies, 0)
    }

    func testApplyFailureRestoresCompleteOriginalConfiguration() {
        let database = PreferencesDatabase(services: [service("wifi", servers: ["10.1.2.3"])])
        let before = database.values
        database.failApplies = 1
        XCTAssertThrowsError(try database.transaction().perform(.select(.publicDNS))) { error in
            XCTAssertTrue(error.localizedDescription.contains("previous DNS settings were restored"))
        }
        XCTAssertEqual(database.values, before)
        XCTAssertEqual(database.activeValues, before)
        XCTAssertEqual(database.commits, 2)
        XCTAssertEqual(database.applies, 2)
    }

    func testRollbackFailureIsReported() {
        let database = PreferencesDatabase(services: [service("wifi")])
        database.failApplies = 2
        XCTAssertThrowsError(try database.transaction().perform(.select(.publicDNS))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Restoring the previous settings also failed"))
            XCTAssertFalse(error.localizedDescription.contains("settings were restored"))
        }
    }

    func testTimedRestoreLeavesExternalEditsAndRemovedServicesAlone() throws {
        let database = PreferencesDatabase(services: [
            service("wifi", servers: DNSProfile.publicServers),
            service("ethernet", kind: .ethernet, servers: ["10.0.0.53"]),
        ])
        let result = try database.transaction().perform(.restoreTimedBypass(serviceIDs: ["wifi", "ethernet", "removed"]))
        XCTAssertEqual(result.targetedServiceIDs, ["wifi"])
        XCTAssertEqual(result.skippedServiceIDs, ["ethernet", "removed"])
        XCTAssertEqual(database.values["ethernet"]?["ServerAddresses"], ["10.0.0.53"])
        XCTAssertNil(database.values["wifi"]?["ServerAddresses"])
    }

    func testTimedRestoreRechecksOwnershipAfterAuthorization() throws {
        let database = PreferencesDatabase(services: [service("wifi", servers: DNSProfile.publicServers)])
        database.onLock = { database.values["wifi"]?["ServerAddresses"] = ["192.168.88.1"] }
        let result = try database.transaction().perform(.restoreTimedBypass(serviceIDs: ["wifi"]))
        XCTAssertEqual(result.skippedServiceIDs, ["wifi"])
        XCTAssertEqual(database.values["wifi"]?["ServerAddresses"], ["192.168.88.1"])
        XCTAssertEqual(database.commits, 0)
    }

    func testModeDetectionIncludesDifferentCustomConfigurations() {
        XCTAssertEqual(DNSMode.mode(for: []), .unavailable)
        XCTAssertEqual(DNSMode.mode(for: [service("wifi")]), .automatic)
        XCTAssertEqual(DNSMode.mode(for: [service("wifi", servers: DNSProfile.publicServers)]), .publicDNS)
        XCTAssertEqual(DNSMode.mode(for: [service("wifi", servers: ["10.0.0.1"])]), .custom)
        XCTAssertEqual(DNSMode.mode(for: [service("wifi"), service("ethernet", servers: DNSProfile.publicServers)]), .mixed)
        XCTAssertEqual(DNSMode.mode(for: [service("a", servers: ["10.0.0.1"]), service("b", servers: ["10.0.0.2"])]), .mixed)
        XCTAssertEqual(DNSMode.mode(for: [service("wifi"), service("vpn", kind: .excluded, servers: ["10.0.0.53"])]), .automatic)
    }
}
