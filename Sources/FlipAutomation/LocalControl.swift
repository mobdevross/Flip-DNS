import Darwin
import Foundation

public struct ControlEndpoint: Sendable {
    public let directory: URL
    public var sessionPath: String { directory.appendingPathComponent("session.json").path }
    var lockPath: String { directory.appendingPathComponent("server.lock").path }

    public static var defaultDirectory: URL {
        // GUI apps and assistant shells may have different TMPDIR values.
        // Darwin's per-user temp directory gives both a stable rendezvous point.
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard count > 0 else {
            return FileManager.default.temporaryDirectory.appendingPathComponent("dev.ross.flip")
        }
        var path = [CChar](repeating: 0, count: count)
        confstr(_CS_DARWIN_USER_TEMP_DIR, &path, path.count)
        return URL(fileURLWithPath: String(cString: path), isDirectory: true).appendingPathComponent("dev.ross.flip")
    }

    public init(directory: URL = ControlEndpoint.defaultDirectory) {
        self.directory = directory
    }

    func validateDirectory() throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            throw ControlFailure("app_unavailable", "Open Flip.app, then try again.")
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(),
              (info.st_mode & 0o077) == 0 else {
            throw ControlFailure("unsafe_endpoint", "Flip's control directory must be private and owned by the current user.")
        }
    }
}

private struct ControlSession: Codable {
    let version: Int
    let sessionID: String

    static func read(from endpoint: ControlEndpoint) throws -> ControlSession {
        let session = try JSONDecoder().decode(Self.self, from: ControlFiles.read(endpoint.sessionPath))
        guard session.version == 1, UUID(uuidString: session.sessionID) != nil else {
            throw ControlFailure("invalid_session", "Open the current version of Flip.app.")
        }
        return session
    }
}

/// All protocol files are bounded, regular files owned by this user. Requests
/// and responses are published by atomic rename so readers never see half JSON.
private enum ControlFiles {
    static let maxBytes = 16_384

    static func openLock(_ endpoint: ControlEndpoint, create: Bool) throws -> Int32 {
        let fd = open(endpoint.lockPath, O_RDWR | O_NOFOLLOW | (create ? O_CREAT : 0), 0o600)
        guard fd >= 0 else { throw ControlFailure("app_unavailable", "Open Flip.app, then try again.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              (info.st_mode & S_IFMT) == S_IFREG, (info.st_mode & 0o077) == 0 else {
            close(fd)
            throw ControlFailure("unsafe_endpoint", "Could not open Flip's control lock safely.")
        }
        return fd
    }

    static func requireActiveServer(_ endpoint: ControlEndpoint) throws {
        let fd = try openLock(endpoint, create: false)
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            throw ControlFailure("app_unavailable", "Open the current version of Flip.app, then try again.")
        }
        guard errno == EWOULDBLOCK else {
            throw ControlFailure("connection_failed", "Could not check Flip's control session.")
        }
    }

    static func read(_ path: String) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ControlFailure("connection_failed", "Could not read a Flip control file.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), (info.st_mode & 0o077) == 0,
              info.st_size >= 0, info.st_size <= maxBytes else {
            throw ControlFailure("unsafe_endpoint", "A control file has unsafe ownership, permissions, type, or size.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= maxBytes {
            let count = Darwin.read(fd, &buffer, min(buffer.count, maxBytes + 1 - data.count))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ControlFailure("connection_failed", "Could not read a control message.") }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw ControlFailure("invalid_message", "Control message is too large.")
    }

    static func write(_ data: Data, to path: String) throws {
        guard data.count <= maxBytes else { throw ControlFailure("invalid_message", "Control message is too large.") }
        let temporary = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp").path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ControlFailure("connection_failed", "Could not create a private control message.") }
        defer { close(fd); unlink(temporary) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ControlFailure("connection_failed", "Could not write the control message.") }
                offset += count
            }
        }
        guard rename(temporary, path) == 0 else {
            throw ControlFailure("connection_failed", "Could not publish the control message.")
        }
    }
}

public enum ControlClient {
    public static func send(_ request: ControlRequest, endpoint: ControlEndpoint = ControlEndpoint(),
                            timeout: TimeInterval = 90) throws -> ControlResponse {
        try endpoint.validateDirectory()
        try ControlFiles.requireActiveServer(endpoint)
        let session = try ControlSession.read(from: endpoint)
        guard UUID(uuidString: request.requestID) != nil else {
            throw ControlFailure("invalid_request", "requestID must be a UUID.")
        }
        let stem = "\(session.sessionID).\(request.requestID)"
        let requestPath = endpoint.directory.appendingPathComponent(stem + ".request.json").path
        let responsePath = endpoint.directory.appendingPathComponent(stem + ".response.json").path
        defer { unlink(requestPath); unlink(responsePath) }
        try ControlFiles.write(JSONEncoder().encode(request), to: requestPath)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var nextSessionCheck: TimeInterval = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            if access(responsePath, F_OK) == 0 {
                let response = try ControlResponse.decode(ControlFiles.read(responsePath))
                guard response.version == 1, response.requestID == request.requestID else {
                    throw ControlFailure("invalid_response", "Flip returned an unexpected control response.")
                }
                return response
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextSessionCheck {
                try ControlFiles.requireActiveServer(endpoint)
                guard try ControlSession.read(from: endpoint).sessionID == session.sessionID else {
                    throw ControlFailure("connection_closed", "Flip restarted. Check status before retrying a change.")
                }
                nextSessionCheck = now + 1
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw ControlFailure("timeout", "Flip may still be waiting for macOS approval. Check flip status before retrying; a timed-out request may still complete.")
    }
}

/// Only the GUI changes DNS and owns timers. The bridge needs no network access:
/// private, same-user files carry requests; each app launch gets a new session
/// so a stale command can never be replayed when Flip starts again.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest, @escaping @Sendable (ControlResponse) -> Void) -> Void
    private let endpoint: ControlEndpoint
    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.ross.flip.control")
    private let session = ControlSession(version: 1, sessionID: UUID().uuidString)
    private var descriptor: Int32 = -1
    private var lockDescriptor: Int32 = -1
    private var ownsSession = false
    private var source: DispatchSourceFileSystemObject?

    public init(endpoint: ControlEndpoint = ControlEndpoint(), handler: @escaping Handler) throws {
        self.endpoint = endpoint
        self.handler = handler
        do { try start() }
        catch { stop(); throw error }
    }

    private func start() throws {
        if mkdir(endpoint.directory.path, 0o700) != 0, errno != EEXIST {
            throw ControlFailure("endpoint_failed", "Could not create Flip's private control directory.")
        }
        try endpoint.validateDirectory()
        lockDescriptor = try ControlFiles.openLock(endpoint, create: true)
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw ControlFailure("already_running", "Another Flip control server is already running.")
        }
        if access(endpoint.sessionPath, F_OK) == 0 {
            _ = try ControlSession.read(from: endpoint)
        }
        removeStaleMessages()
        try ControlFiles.write(JSONEncoder().encode(session), to: endpoint.sessionPath)
        ownsSession = true
        descriptor = open(endpoint.directory.path, O_EVTONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ControlFailure("endpoint_failed", "Could not observe Flip's control directory.") }
        let watchedFD = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: watchedFD,
                                                               eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in self?.processRequests() }
        source.setCancelHandler { close(watchedFD) }
        self.source = source
        source.resume()
        queue.async { [weak self] in self?.processRequests() }
    }

    private func processRequests() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: endpoint.directory.path) else { return }
        for name in names {
            guard name.hasPrefix(session.sessionID + "."), name.hasSuffix(".request.json") else { continue }
            let id = String(name.dropFirst(session.sessionID.count + 1).dropLast(".request.json".count))
            guard UUID(uuidString: id) != nil else { continue }
            let stem = session.sessionID + "." + id
            let incoming = endpoint.directory.appendingPathComponent(name).path
            let processing = endpoint.directory.appendingPathComponent(stem + ".processing.json").path
            let outgoing = endpoint.directory.appendingPathComponent(stem + ".response.json").path
            // Claim before handing work to the main actor; directory events may
            // fire repeatedly while macOS is waiting for approval.
            guard rename(incoming, processing) == 0 else { continue }
            let queue = self.queue
            let reply: @Sendable (ControlResponse) -> Void = { response in
                queue.async {
                    try? ControlFiles.write(response.encoded(), to: outgoing)
                    unlink(processing)
                    queue.asyncAfter(deadline: .now() + 300) { unlink(outgoing) }
                }
            }
            do {
                let request = try JSONDecoder().decode(ControlRequest.self, from: ControlFiles.read(processing))
                guard request.requestID == id else {
                    throw ControlFailure("invalid_request", "Request ID does not match the message filename.")
                }
                handler(request, reply)
            } catch {
                reply(ControlResponse(requestID: id, error: error as? ControlFailure ??
                    ControlFailure("invalid_request", "Send a valid JSON control request.")))
            }
        }
    }

    private func removeStaleMessages() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: endpoint.directory.path) else { return }
        for name in names {
            let parts = name.split(separator: ".")
            guard parts.count == 4, UUID(uuidString: String(parts[0])) != nil,
                  UUID(uuidString: String(parts[1])) != nil,
                  ["request", "processing", "response"].contains(String(parts[2])), parts[3] == "json" else { continue }
            let path = endpoint.directory.appendingPathComponent(name).path
            var info = stat()
            if lstat(path, &info) == 0, info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFREG {
                unlink(path)
            }
        }
    }

    private func stop() {
        if let source { source.cancel(); self.source = nil }
        else if descriptor >= 0 { close(descriptor) }
        descriptor = -1
        if ownsSession { unlink(endpoint.sessionPath); ownsSession = false }
        if lockDescriptor >= 0 { close(lockDescriptor); lockDescriptor = -1 }
    }

    deinit { stop() }
}
