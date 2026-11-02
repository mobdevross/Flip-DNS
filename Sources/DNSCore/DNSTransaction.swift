import Foundation

/// A session stages changes in memory until commit. It retains complete original
/// DNS dictionaries, including search domains, for recovery after a failed apply.
public protocol DNSPreferencesSession: AnyObject {
    func readServices() throws -> [DNSService]
    func lock() throws
    func unlock()
    func setServers(_ servers: [String], serviceID: String) throws
    func commit() throws
    func apply() throws
    func stageOriginalConfigurations() throws
}

public final class DNSTransaction {
    public typealias SessionFactory = (_ authorized: Bool) throws -> DNSPreferencesSession
    private let makeSession: SessionFactory

    public init(makeSession: @escaping SessionFactory) {
        self.makeSession = makeSession
    }

    public func readServices() throws -> [DNSService] {
        try makeSession(false).readServices()
    }

    public func perform(_ change: DNSChange) throws -> DNSChangeResult {
        let initial = try readServices()
        let initialTargets = change.targets(in: initial)
        if case .select = change, initialTargets.isEmpty { throw DNSError.noServices }

        // Reading the menu, or selecting an already active mode, must not prompt.
        guard initialTargets.contains(where: { !change.profile.matches($0.servers) }) else {
            return result(change: change, targets: initialTargets, services: initial)
        }

        let session = try makeSession(true)
        try session.lock()
        defer { session.unlock() }

        // Re-evaluate under the preferences lock, including ownership checks for
        // timed restoration. An external edit made during authorization wins.
        let current = try session.readServices()
        let targets = change.targets(in: current)
        if case .select = change, targets.isEmpty { throw DNSError.noServices }
        let changed = targets.filter { !change.profile.matches($0.servers) }
        guard !changed.isEmpty else {
            return result(change: change, targets: targets, services: current)
        }
        for service in changed {
            try session.setServers(change.profile.servers, serviceID: service.id)
        }
        // A staging or commit failure has not applied changes to the system.
        try session.commit()
        do {
            try session.apply()
            let verified = try readServices()
            for target in targets {
                guard let service = verified.first(where: { $0.id == target.id }),
                      change.profile.matches(service.servers) else {
                    throw DNSError.operation("The DNS settings could not be verified after applying the change.")
                }
            }
            return result(change: change, targets: targets, services: verified)
        } catch {
            let original = error.localizedDescription
            var rollbackError: String?
            do {
                try session.stageOriginalConfigurations()
                try session.commit()
                try session.apply()
            } catch {
                rollbackError = error.localizedDescription
            }
            throw DNSError.recovery(original: original, rollback: rollbackError)
        }
    }

    private func result(change: DNSChange, targets: [DNSService],
                        services: [DNSService]) -> DNSChangeResult {
        let ids = Set(targets.map(\.id))
        let skipped: Set<String>
        if case let .restoreTimedBypass(originalIDs) = change {
            skipped = originalIDs.subtracting(ids)
        } else {
            skipped = []
        }
        return DNSChangeResult(services: services, targetedServiceIDs: ids,
                               skippedServiceIDs: skipped)
    }
}

public protocol DNSBackend: AnyObject {
    func readServices() async throws -> [DNSService]
    func perform(_ change: DNSChange) async throws -> DNSChangeResult
}
