import DNSCore
import FlipAutomation
import XCTest

private final class MemoryStorage: BypassStorage {
    var value: TimedBypass?
    func load() -> TimedBypass? { value }
    func save(_ bypass: TimedBypass?) { value = bypass }
}

private final class AutomationBackend: DNSBackend {
    var services = [DNSService(id: "wifi", name: "Wi-Fi", device: "en0", kind: .wifi)]
    var changes: [DNSChange] = []
    var failChange = false
    var suspendChange = false
    var continuation: CheckedContinuation<Void, Never>?

    func readServices() async throws -> [DNSService] { services }
    func perform(_ change: DNSChange) async throws -> DNSChangeResult {
        changes.append(change)
        if suspendChange { await withCheckedContinuation { continuation = $0 } }
        if failChange { throw DNSError.operation("Administrator approval was cancelled") }
        let ids = Set(change.targets(in: services).map(\.id))
        services = services.map {
            DNSService(id: $0.id, name: $0.name, device: $0.device, kind: $0.kind,
                       isEnabled: $0.isEnabled, servers: ids.contains($0.id) ? change.profile.servers : $0.servers)
        }
        let skipped: Set<String>
        if case let .restoreTimedBypass(originalIDs) = change { skipped = originalIDs.subtracting(ids) }
        else { skipped = [] }
        return DNSChangeResult(services: services, targetedServiceIDs: ids, skippedServiceIDs: skipped)
    }
}

final class AutomationTests: XCTestCase {
    func testCLIProvidesOnlyBoundedBypasses() throws {
        if case let .control(request) = try CLIInvocation.parse(["bypass"]) {
            XCTAssertEqual(request.command, .bypass)
            XCTAssertEqual(request.minutes, 15)
        } else { XCTFail("Expected a bypass command") }
        for minutes in [5, 15, 60] {
            if case let .control(request) = try CLIInvocation.parse(["bypass", "--minutes", String(minutes)]) {
                XCTAssertEqual(request.minutes, minutes)
            } else { XCTFail("Expected a bypass command") }
        }
        for arguments in [["bypass", "--minutes", "0"], ["bypass", "--minutes", "120"],
                          ["public"], ["bypass", "--minutes"], ["restore", "--minutes", "15"],
                          ["bypass", "--minutes", "15; echo nope"]] {
            XCTAssertThrowsError(try CLIInvocation.parse(arguments))
        }
    }

    func testEmptyCLIInvocationShowsHelpWithoutLaunchingAnotherGUI() throws {
        if case .help = try CLIInvocation.parse([], executableName: "flip") {} else { XCTFail("Expected help") }
        if case .gui = try CLIInvocation.parse([]) {} else { XCTFail("Expected GUI launch") }
        if case .gui = try CLIInvocation.parse(["-psn_0_1"]) {} else { XCTFail("Expected LaunchServices launch") }
    }

    @MainActor
    func testBypassUsesAppTimerAndRestoreEndsIt() async {
        let backend = AutomationBackend()
        let storage = MemoryStorage()
        let now = Date(timeIntervalSince1970: 2_000)
        let model = SwitcherModel(backend: backend, storage: storage, now: { now })
        let service = ControlService(model: model, now: { now })
        let bypass = await service.handle(ControlRequest(command: .bypass, minutes: 5))
        XCTAssertTrue(bypass.ok)
        XCTAssertEqual(bypass.status?.mode, "public")
        XCTAssertEqual(bypass.status?.remainingSeconds, 300)
        XCTAssertEqual(bypass.status?.expiresAt, now.addingTimeInterval(300))
        XCTAssertNotNil(storage.value)
        let restored = await service.handle(ControlRequest(command: .restore))
        XCTAssertTrue(restored.ok)
        XCTAssertEqual(restored.status?.mode, "automatic")
        XCTAssertNil(restored.status?.expiresAt)
        XCTAssertNil(storage.value)
    }

    @MainActor
    func testInvalidRequestsCannotChangeDNS() async {
        let backend = AutomationBackend()
        let model = SwitcherModel(backend: backend, storage: MemoryStorage())
        let service = ControlService(model: model)
        let invalid = [
            ControlRequest(command: .bypass, minutes: 120),
            ControlRequest(command: .bypass),
            ControlRequest(command: .bypass, minutes: 15, version: 2),
            ControlRequest(command: .bypass, minutes: 15, requestID: "not-a-uuid"),
            ControlRequest(command: .restore, minutes: 15),
        ]
        for request in invalid {
            let result = await service.handle(request)
            XCTAssertFalse(result.ok)
            XCTAssertNotNil(result.error)
        }
        XCTAssertTrue(backend.changes.isEmpty)
        XCTAssertNil(model.bypass)
    }

    @MainActor
    func testRestoreWithoutActiveBypassPreservesCustomDNS() async {
        let backend = AutomationBackend()
        backend.services = [DNSService(id: "wifi", name: "Wi-Fi", device: "en0", kind: .wifi, servers: ["10.0.0.53"])]
        let service = ControlService(model: SwitcherModel(backend: backend, storage: MemoryStorage()))
        let result = await service.handle(ControlRequest(command: .restore))
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.status?.mode, "custom")
        XCTAssertTrue(backend.changes.isEmpty)
    }

    @MainActor
    func testApprovalFailureIsReportedWithoutStartingTimer() async {
        let backend = AutomationBackend()
        backend.failChange = true
        let storage = MemoryStorage()
        let service = ControlService(model: SwitcherModel(backend: backend, storage: storage))
        let result = await service.handle(ControlRequest(command: .bypass, minutes: 15))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error?.code, "change_failed")
        XCTAssertEqual(result.status?.mode, "automatic")
        XCTAssertNil(storage.value)
    }

    func testJSONResponseRoundTripPreservesMachineReadableStatus() throws {
        let status = ControlStatus(mode: "public", busy: false, expiresAt: Date(timeIntervalSince1970: 2_000),
                                   remainingSeconds: 60, restorePending: false)
        let response = ControlResponse(requestID: UUID().uuidString, status: status)
        let data = try response.encoded()
        let decoded = try ControlResponse.decode(data)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.requestID, response.requestID)
        XCTAssertEqual(decoded.status?.expiresAt, status.expiresAt)
        XCTAssertEqual(decoded.status?.mode, "public")
    }

    @MainActor
    func testStatusRemainsResponsiveWhileApprovalIsPending() async {
        let backend = AutomationBackend()
        backend.suspendChange = true
        let model = SwitcherModel(backend: backend, storage: MemoryStorage())
        let service = ControlService(model: model)
        let pending = Task { await service.handle(ControlRequest(command: .bypass, minutes: 15)) }
        while backend.continuation == nil { await Task.yield() }
        let status = await service.handle(ControlRequest(command: .status))
        XCTAssertTrue(status.ok)
        XCTAssertEqual(status.status?.busy, true)
        let duplicate = await service.handle(ControlRequest(command: .bypass, minutes: 5))
        XCTAssertFalse(duplicate.ok)
        XCTAssertEqual(duplicate.error?.code, "busy")
        XCTAssertEqual(backend.changes.count, 1)
        backend.continuation?.resume()
        let completed = await pending.value
        XCTAssertTrue(completed.ok)
        XCTAssertEqual(completed.status?.busy, false)
    }

    func testStaleRequestsCannotReplayAfterRestart() throws {
        let endpoint = temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: endpoint.directory) }
        var first: ControlServer? = try ControlServer(endpoint: endpoint) { request, reply in
            reply(ControlResponse(requestID: request.requestID))
        }
        let session = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: endpoint.sessionPath))) as? [String: Any])
        let oldID = try XCTUnwrap(session["sessionID"] as? String)
        withExtendedLifetime(first) {}
        first = nil
        let staleRequest = ControlRequest(command: .bypass, minutes: 15)
        let stalePath = endpoint.directory.appendingPathComponent("\(oldID).\(staleRequest.requestID).request.json")
        try JSONEncoder().encode(staleRequest).write(to: stalePath)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stalePath.path)
        let replayed = expectation(description: "A stale bypass must not run")
        replayed.isInverted = true
        let server = try ControlServer(endpoint: endpoint) { request, reply in
            if request.command == .bypass { replayed.fulfill() }
            reply(ControlResponse(requestID: request.requestID))
        }
        defer { withExtendedLifetime(server) {} }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stalePath.path))
        XCTAssertTrue(try ControlClient.send(ControlRequest(command: .status), endpoint: endpoint, timeout: 3).ok)
        wait(for: [replayed], timeout: 0.1)
    }

    @MainActor
    func testLocalRequestChangesTheSharedModelAndPersistsItsTimer() async throws {
        let endpoint = temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: endpoint.directory) }
        let backend = AutomationBackend()
        let storage = MemoryStorage()
        let model = SwitcherModel(backend: backend, storage: storage)
        let service = ControlService(model: model)
        let server = try ControlServer(endpoint: endpoint) { request, reply in
            Task { @MainActor in reply(await service.handle(request)) }
        }
        defer { withExtendedLifetime(server) {} }
        let result = try await Task.detached {
            try ControlClient.send(ControlRequest(command: .bypass, minutes: 15), endpoint: endpoint, timeout: 3)
        }.value
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.status?.mode, "public")
        XCTAssertEqual(result.status?.remainingSeconds, 900)
        XCTAssertNotNil(storage.value)
        XCTAssertEqual(model.mode, .publicDNS)
        let restored = try await Task.detached {
            try ControlClient.send(ControlRequest(command: .restore), endpoint: endpoint, timeout: 3)
        }.value
        XCTAssertTrue(restored.ok)
        XCTAssertEqual(restored.status?.mode, "automatic")
        XCTAssertNil(storage.value)
    }

    func testSecondServerCannotReplaceTheActiveSession() throws {
        let endpoint = temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: endpoint.directory) }
        let handler: ControlServer.Handler = { request, reply in reply(ControlResponse(requestID: request.requestID)) }
        let server = try ControlServer(endpoint: endpoint, handler: handler)
        defer { withExtendedLifetime(server) {} }
        XCTAssertThrowsError(try ControlServer(endpoint: endpoint, handler: handler)) { error in
            XCTAssertEqual((error as? ControlFailure)?.code, "already_running")
        }
        let response = try ControlClient.send(ControlRequest(command: .status), endpoint: endpoint, timeout: 3)
        XCTAssertTrue(response.ok)
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: endpoint.directory.path)[.posixPermissions] as? NSNumber
        let sessionPermissions = try FileManager.default.attributesOfItem(atPath: endpoint.sessionPath)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)
        XCTAssertEqual(sessionPermissions?.intValue, 0o600)
    }

    func testSharedDirectoryAndInvalidSessionAreRejectedWithoutDeletingFiles() throws {
        let endpoint = temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: endpoint.directory) }
        try FileManager.default.createDirectory(at: endpoint.directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: endpoint.directory.path)
        let handler: ControlServer.Handler = { request, reply in reply(ControlResponse(requestID: request.requestID)) }
        XCTAssertThrowsError(try ControlServer(endpoint: endpoint, handler: handler)) { error in
            XCTAssertEqual((error as? ControlFailure)?.code, "unsafe_endpoint")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: endpoint.directory.path)
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: endpoint.sessionPath))
        XCTAssertThrowsError(try ControlServer(endpoint: endpoint, handler: handler))
        XCTAssertEqual(try String(contentsOfFile: endpoint.sessionPath), "keep me")
    }

    func testMissingAppReturnsActionableError() {
        XCTAssertThrowsError(try ControlClient.send(ControlRequest(command: .status), endpoint: temporaryEndpoint())) { error in
            XCTAssertEqual((error as? ControlFailure)?.code, "app_unavailable")
        }
    }

    func testTimeoutDoesNotPretendTheRequestWasCancelled() throws {
        let endpoint = temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: endpoint.directory) }
        let server = try ControlServer(endpoint: endpoint) { request, reply in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                reply(ControlResponse(requestID: request.requestID))
            }
        }
        defer { withExtendedLifetime(server) {} }
        XCTAssertThrowsError(try ControlClient.send(ControlRequest(command: .status), endpoint: endpoint, timeout: 0.05)) { error in
            XCTAssertEqual((error as? ControlFailure)?.code, "timeout")
            XCTAssertTrue(error.localizedDescription.contains("may still complete"))
        }
    }

    private func temporaryEndpoint() -> ControlEndpoint {
        ControlEndpoint(directory: FileManager.default.temporaryDirectory.appendingPathComponent("flip-ctl-\(UUID().uuidString.prefix(8))"))
    }
}
