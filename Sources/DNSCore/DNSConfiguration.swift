import Foundation

public enum DNSProfile: String, Sendable {
    case automatic
    case publicDNS

    public static let publicServers = [
        "1.1.1.1", "1.0.0.1",
        "2606:4700:4700::1111", "2606:4700:4700::1001",
    ]

    public var servers: [String] {
        self == .automatic ? [] : Self.publicServers
    }

    public func matches(_ addresses: [String]) -> Bool {
        Set(addresses.map { $0.lowercased() }) == Set(servers)
    }
}

public enum DNSMode: String, Sendable {
    case automatic = "Automatic"
    case publicDNS = "Public DNS"
    case custom = "Custom DNS"
    case mixed = "Mixed DNS"
    case unavailable = "Unavailable"

    public static func mode(for services: [DNSService]) -> DNSMode {
        let eligible = services.filter(\.isEligible)
        guard !eligible.isEmpty else { return .unavailable }
        let modes = Set(eligible.map(\.mode))
        if modes.count != 1 { return .mixed }
        // Different custom resolver sets are also a mixed configuration.
        if modes.first == .custom,
           Set(eligible.map { Set($0.servers.map { $0.lowercased() }) }).count > 1 {
            return .mixed
        }
        return eligible[0].mode
    }
}

public enum DNSInterfaceKind: String, Codable, Sendable {
    case wifi, ethernet, excluded
}

public struct DNSService: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let name: String
    public let device: String
    public let kind: DNSInterfaceKind
    public let isEnabled: Bool
    public let servers: [String]

    public init(id: String, name: String, device: String, kind: DNSInterfaceKind,
                isEnabled: Bool = true, servers: [String] = []) {
        self.id = id
        self.name = name
        self.device = device
        self.kind = kind
        self.isEnabled = isEnabled
        self.servers = servers
    }

    public var isEligible: Bool { isEnabled && kind != .excluded }

    public var mode: DNSMode {
        if servers.isEmpty { return .automatic }
        return DNSProfile.publicDNS.matches(servers) ? .publicDNS : .custom
    }
}

public enum DNSChange: Equatable, Sendable {
    case select(DNSProfile)
    case restoreTimedBypass(serviceIDs: Set<String>)

    public var profile: DNSProfile {
        if case let .select(profile) = self { return profile }
        return .automatic
    }

    public func targets(in services: [DNSService]) -> [DNSService] {
        let eligible = services.filter(\.isEligible)
        switch self {
        case .select:
            return eligible
        case let .restoreTimedBypass(serviceIDs):
            return eligible.filter {
                serviceIDs.contains($0.id) && DNSProfile.publicDNS.matches($0.servers)
            }
        }
    }
}

public struct DNSChangeResult: Sendable {
    public let services: [DNSService]
    public let targetedServiceIDs: Set<String>
    public let skippedServiceIDs: Set<String>

    public init(services: [DNSService], targetedServiceIDs: Set<String>,
                skippedServiceIDs: Set<String> = []) {
        self.services = services
        self.targetedServiceIDs = targetedServiceIDs
        self.skippedServiceIDs = skippedServiceIDs
    }
}

public enum DNSError: LocalizedError {
    case noServices
    case operation(String)
    case recovery(original: String, rollback: String?)

    public var errorDescription: String? {
        switch self {
        case .noServices:
            return "No enabled Wi-Fi or Ethernet services are available in this network location."
        case let .operation(message):
            return message
        case let .recovery(original, rollback):
            if let rollback {
                return "\(original) Restoring the previous settings also failed: \(rollback) Check DNS in System Settings."
            }
            return "\(original) The previous DNS settings were restored."
        }
    }
}
