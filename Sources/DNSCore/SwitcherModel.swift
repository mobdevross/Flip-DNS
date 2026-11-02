import Combine
import Foundation

public struct TimedBypass: Codable, Equatable, Sendable {
    public let deadline: Date
    public let serviceIDs: Set<String>
    public var restorePending: Bool

    public init(deadline: Date, serviceIDs: Set<String>, restorePending: Bool = false) {
        self.deadline = deadline
        self.serviceIDs = serviceIDs
        self.restorePending = restorePending
    }
}

public protocol BypassStorage: AnyObject {
    func load() -> TimedBypass?
    func save(_ bypass: TimedBypass?)
}

public final class DefaultsBypassStorage: BypassStorage {
    private let defaults: UserDefaults
    private let key = "timedBypass.v1"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> TimedBypass? {
        guard let data = defaults.data(forKey: key),
              let bypass = try? JSONDecoder().decode(TimedBypass.self, from: data),
              !bypass.serviceIDs.isEmpty else { return nil }
        return bypass
    }

    public func save(_ bypass: TimedBypass?) {
        if let bypass, let data = try? JSONEncoder().encode(bypass) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

@MainActor
public final class SwitcherModel: ObservableObject {
    @Published public private(set) var services: [DNSService] = []
    @Published public private(set) var isReadable = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var bypass: TimedBypass?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var information: String?

    private let backend: DNSBackend
    private let storage: BypassStorage
    private let now: () -> Date
    private var generation = 0
    private var readFailed = false

    public init(backend: DNSBackend, storage: BypassStorage,
                now: @escaping () -> Date = Date.init) {
        self.backend = backend
        self.storage = storage
        self.now = now
        self.bypass = storage.load()
    }

    public var mode: DNSMode { isReadable ? DNSMode.mode(for: services) : .unavailable }
    public var eligibleServices: [DNSService] { services.filter(\.isEligible) }

    public func refresh() async {
        guard !isBusy else { return }
        let startedGeneration = generation
        do {
            let latest = try await backend.readServices()
            guard generation == startedGeneration, !isBusy else { return }
            services = latest
            isReadable = true
            if readFailed { errorMessage = nil }
            readFailed = false
        } catch {
            guard generation == startedGeneration, !isBusy else { return }
            isReadable = false
            errorMessage = error.localizedDescription
            readFailed = true
        }
    }

    @discardableResult
    public func choose(_ profile: DNSProfile, minutes: Int? = nil) async -> Bool {
        guard !isBusy else { return false }
        if let minutes, (profile != .publicDNS || ![5, 15, 60].contains(minutes)) {
            errorMessage = "Choose a public DNS bypass of 5, 15, or 60 minutes."
            return false
        }
        beginOperation()
        defer { isBusy = false }
        do {
            let result = try await backend.perform(.select(profile))
            services = result.services
            isReadable = true
            if let minutes {
                bypass = TimedBypass(deadline: now().addingTimeInterval(Double(minutes) * 60),
                                     serviceIDs: result.targetedServiceIDs)
            } else {
                bypass = nil
            }
            storage.save(bypass)
            return true
        } catch {
            await recoverAfterFailure(error)
            return false
        }
    }

    public func checkDeadline() async {
        guard let bypass, bypass.deadline <= now(), !bypass.restorePending, !isBusy else { return }
        await restoreTimedBypass()
    }

    @discardableResult
    public func restoreTimedBypass() async -> Bool {
        guard var scheduled = bypass else { return true }
        guard !isBusy else { return false }
        beginOperation()
        defer { isBusy = false }
        scheduled.restorePending = true
        bypass = scheduled
        storage.save(scheduled)
        do {
            let result = try await backend.perform(.restoreTimedBypass(serviceIDs: scheduled.serviceIDs))
            services = result.services
            isReadable = true
            bypass = nil
            storage.save(nil)
            if !result.skippedServiceIDs.isEmpty {
                information = "The timer ended. Services changed elsewhere or no longer available were left unchanged."
            }
            return true
        } catch {
            await recoverAfterFailure(error)
            return false
        }
    }

    public func abandonTimer() {
        guard !isBusy else { return }
        bypass = nil
        storage.save(nil)
    }

    private func beginOperation() {
        generation += 1
        isBusy = true
        readFailed = false
        errorMessage = nil
        information = nil
    }

    private func recoverAfterFailure(_ error: Error) async {
        errorMessage = error.localizedDescription
        // The disk or active configuration may have changed even when apply or
        // recovery failed. Never retain a checkmark based on a previous snapshot.
        do {
            services = try await backend.readServices()
            isReadable = true
        } catch {
            isReadable = false
        }
    }
}
