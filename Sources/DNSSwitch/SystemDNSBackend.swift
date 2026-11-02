import DNSCore
import Foundation
import Security
import SystemConfiguration

private func configurationError(_ action: String) -> Error {
    let code = SCError()
    if code == kSCStatusAccessError {
        return DNSError.operation("macOS did not authorize the DNS change. Try again and approve the administrator prompt.")
    }
    let detail = String(cString: SCErrorString(code))
    return DNSError.operation("\(action): \(detail)")
}

/// All access to this reference and the preferences sessions happens on the
/// backend's serial queue. macOS decides when cached authorization expires.
private final class NetworkAuthorization {
    private var reference: AuthorizationRef?

    func get() throws -> AuthorizationRef {
        if let reference { return reference }
        var created: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [], &created)
        guard status == errAuthorizationSuccess, let created else {
            throw DNSError.operation("Could not start macOS authorization (\(status)).")
        }
        reference = created
        return created
    }

    deinit {
        if let reference { AuthorizationFree(reference, []) }
    }
}

private final class NativePreferencesSession: DNSPreferencesSession {
    private struct OriginalDNS {
        let hadProtocol: Bool
        let configuration: CFDictionary?
    }

    private let preferences: SCPreferences
    private var originals: [String: OriginalDNS] = [:]

    init(authorization: AuthorizationRef?) throws {
        let created: SCPreferences?
        if let authorization {
            created = SCPreferencesCreateWithAuthorization(nil, "Flip" as CFString, nil, authorization)
        } else {
            created = SCPreferencesCreate(nil, "Flip" as CFString, nil)
        }
        guard let created else { throw configurationError("Could not read network preferences") }
        preferences = created
    }

    private func currentServices() throws -> [SCNetworkService] {
        guard let current = SCNetworkSetCopyCurrent(preferences) else {
            throw configurationError("Could not read the current network location")
        }
        return SCNetworkSetCopyServices(current) as? [SCNetworkService] ?? []
    }

    func readServices() throws -> [DNSService] {
        try currentServices().map { service in
            guard let id = SCNetworkServiceGetServiceID(service) as String? else {
                throw DNSError.operation("A network service has no identifier.")
            }
            let name = SCNetworkServiceGetName(service) as String? ?? id
            let interface = SCNetworkServiceGetInterface(service)
            let device = interface.flatMap { SCNetworkInterfaceGetBSDName($0) as String? } ?? ""
            let type = interface.flatMap { SCNetworkInterfaceGetInterfaceType($0) as String? }
            let kind: DNSInterfaceKind
            if type == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                kind = .wifi
            } else if type == (kSCNetworkInterfaceTypeEthernet as String), !device.hasPrefix("bridge") {
                kind = .ethernet
            } else {
                kind = .excluded
            }
            let dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS)
            let config = dns.flatMap { SCNetworkProtocolGetConfiguration($0) as? [String: Any] }
            let servers = config?[kSCPropNetDNSServerAddresses as String] as? [String] ?? []
            return DNSService(id: id, name: name, device: device, kind: kind,
                              isEnabled: SCNetworkServiceGetEnabled(service), servers: servers)
        }.sorted {
            if $0.kind == .wifi && $1.kind != .wifi { return true }
            if $0.kind != .wifi && $1.kind == .wifi { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func lock() throws {
        guard SCPreferencesLock(preferences, false) else {
            throw configurationError("Could not lock network preferences; another app may be changing them")
        }
    }

    func unlock() { SCPreferencesUnlock(preferences) }

    private func service(withID id: String) throws -> SCNetworkService {
        guard let service = try currentServices().first(where: {
            (SCNetworkServiceGetServiceID($0) as String?) == id
        }) else {
            throw DNSError.operation("A network service disappeared before DNS could be changed. Try again.")
        }
        return service
    }

    func setServers(_ servers: [String], serviceID: String) throws {
        let service = try service(withID: serviceID)
        var dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS)
        if originals[serviceID] == nil {
            originals[serviceID] = OriginalDNS(
                hadProtocol: dns != nil,
                configuration: dns.flatMap { SCNetworkProtocolGetConfiguration($0) }
            )
        }
        if dns == nil {
            guard SCNetworkServiceAddProtocolType(service, kSCNetworkProtocolTypeDNS) else {
                throw configurationError("Could not add DNS settings to \(serviceID)")
            }
            dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS)
        }
        guard let dns else { throw configurationError("Could not open DNS settings") }
        var config = SCNetworkProtocolGetConfiguration(dns) as? [String: Any] ?? [:]
        if servers.isEmpty {
            config.removeValue(forKey: kSCPropNetDNSServerAddresses as String)
        } else {
            config[kSCPropNetDNSServerAddresses as String] = servers
        }
        guard SCNetworkProtocolSetConfiguration(dns, config as CFDictionary) else {
            throw configurationError("Could not stage DNS settings")
        }
    }

    func commit() throws {
        guard SCPreferencesCommitChanges(preferences) else {
            throw configurationError("Could not save DNS settings")
        }
    }

    func apply() throws {
        guard SCPreferencesApplyChanges(preferences) else {
            throw configurationError("Could not apply DNS settings")
        }
    }

    func stageOriginalConfigurations() throws {
        for (id, original) in originals {
            let service = try service(withID: id)
            if !original.hadProtocol {
                guard SCNetworkServiceRemoveProtocolType(service, kSCNetworkProtocolTypeDNS) else {
                    throw configurationError("Could not restore the previous DNS protocol")
                }
            } else {
                guard let dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS),
                      SCNetworkProtocolSetConfiguration(dns, original.configuration) else {
                    throw configurationError("Could not restore the previous DNS settings")
                }
            }
        }
    }
}

// Mutable preferences and authorization state are confined to `queue`.
final class SystemDNSBackend: DNSBackend, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.ross.dns-switch.network", qos: .userInitiated)
    private let transaction: DNSTransaction

    init() {
        let authorization = NetworkAuthorization()
        transaction = DNSTransaction { authorized in
            try NativePreferencesSession(authorization: authorized ? authorization.get() : nil)
        }
    }

    func readServices() async throws -> [DNSService] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result { try transaction.readServices() })
            }
        }
    }

    func perform(_ change: DNSChange) async throws -> DNSChangeResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result { try transaction.perform(change) })
            }
        }
    }

    /// Used only by the read-only --diagnose command before the app run loop.
    func diagnose() throws -> [DNSService] { try transaction.readServices() }
}
