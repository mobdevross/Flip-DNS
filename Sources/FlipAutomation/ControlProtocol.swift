import DNSCore
import Foundation

public enum ControlCommand: String, Codable, Sendable {
    case status, bypass, restore
}

public struct ControlRequest: Codable, Sendable {
    public let version: Int
    public let requestID: String
    public let command: ControlCommand
    public let minutes: Int?

    public init(command: ControlCommand, minutes: Int? = nil, version: Int = 1,
                requestID: String = UUID().uuidString) {
        self.version = version
        self.requestID = requestID
        self.command = command
        self.minutes = minutes
    }
}

public struct ControlStatus: Codable, Sendable {
    public let mode: String
    public let busy: Bool
    public let expiresAt: Date?
    public let remainingSeconds: Int?
    public let restorePending: Bool

    public init(mode: String, busy: Bool, expiresAt: Date?, remainingSeconds: Int?, restorePending: Bool) {
        self.mode = mode
        self.busy = busy
        self.expiresAt = expiresAt
        self.remainingSeconds = remainingSeconds
        self.restorePending = restorePending
    }
}

public struct ControlFailure: Codable, Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

public struct ControlResponse: Codable, Sendable {
    public let version: Int
    public let requestID: String?
    public let ok: Bool
    public let status: ControlStatus?
    public let error: ControlFailure?

    public init(requestID: String? = nil, status: ControlStatus? = nil, error: ControlFailure? = nil) {
        version = 1
        self.requestID = requestID
        ok = error == nil
        self.status = status
        self.error = error
    }

    public func encoded(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ControlResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: data)
    }
}

@MainActor
public final class ControlService {
    private let model: SwitcherModel
    private let now: () -> Date

    public init(model: SwitcherModel, now: @escaping () -> Date = Date.init) {
        self.model = model
        self.now = now
    }

    public func handle(_ request: ControlRequest) async -> ControlResponse {
        guard request.version == 1 else {
            return response(request, error: ControlFailure("unsupported_version", "Use control protocol version 1."))
        }
        guard UUID(uuidString: request.requestID) != nil else {
            return response(request, error: ControlFailure("invalid_request", "requestID must be a UUID."))
        }
        if request.command == .bypass {
            guard let minutes = request.minutes, [5, 15, 60].contains(minutes) else {
                return response(request, error: ControlFailure("invalid_duration", "Choose 5, 15, or 60 minutes."))
            }
        } else if request.minutes != nil {
            return response(request, error: ControlFailure("invalid_request", "Only bypass accepts minutes."))
        }
        if request.command == .status {
            await model.refresh()
            return response(request, error: model.isReadable || model.isBusy ? nil :
                ControlFailure("read_failed", model.errorMessage ?? "DNS settings are unavailable."))
        }
        guard !model.isBusy else {
            return response(request, error: ControlFailure("busy", "Flip is changing DNS or waiting for macOS approval. Check status before retrying."))
        }
        let succeeded: Bool
        switch request.command {
        case .bypass:
            succeeded = await model.choose(.publicDNS, minutes: request.minutes)
        case .restore:
            // End the app's active bypass; never clear unrelated custom DNS.
            succeeded = await model.restoreTimedBypass()
            if model.bypass == nil { await model.refresh() }
        case .status:
            succeeded = true
        }
        if succeeded, !model.isReadable {
            return response(request, error: ControlFailure("read_failed", model.errorMessage ?? "DNS settings are unavailable."))
        }
        return response(request, error: succeeded ? nil :
            ControlFailure("change_failed", model.errorMessage ?? "DNS could not be changed. Check Flip and approve the macOS prompt if requested."))
    }

    private func response(_ request: ControlRequest, error: ControlFailure? = nil) -> ControlResponse {
        let mode: String
        switch model.mode {
        case .automatic: mode = "automatic"
        case .publicDNS: mode = "public"
        case .custom: mode = "custom"
        case .mixed: mode = "mixed"
        case .unavailable: mode = "unavailable"
        }
        let status = ControlStatus(mode: mode, busy: model.isBusy, expiresAt: model.bypass?.deadline,
                                   remainingSeconds: model.bypass.map { max(0, Int(ceil($0.deadline.timeIntervalSince(now())))) },
                                   restorePending: model.bypass?.restorePending ?? false)
        return ControlResponse(requestID: request.requestID, status: status, error: error)
    }
}
