import Darwin
import Foundation

enum ApplicationInstallationError: LocalizedError {
    case invalidBundle
    case destinationOccupied
    case replacementNotApproved

    var errorDescription: String? {
        switch self {
        case .invalidBundle:
            return "This does not appear to be a complete Flip application bundle."
        case .destinationOccupied:
            return "The destination contains another item named Flip.app. Move or rename it in Finder before installing Flip."
        case .replacementNotApproved:
            return "A copy of Flip is already installed. Confirm replacement before installing this build."
        }
    }
}

struct ApplicationInstallation {
    static let identifier = "dev.ross.dns-switch"
    let fileManager: FileManager

    init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    static var applicationsDirectories: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    }

    static func isInstalled(_ bundleURL: URL, in directories: [URL] = applicationsDirectories) -> Bool {
        let path = bundleURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return directories.contains { directory in
            let root = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            return path.count > root.count && path.starts(with: root)
        }
    }

    func info(at bundleURL: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    }

    func isFlipBundle(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "app", let metadata = info(at: url),
              metadata["CFBundleIdentifier"] as? String == Self.identifier,
              metadata["CFBundleExecutable"] as? String == "DNSSwitch" else { return false }
        return fileManager.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/DNSSwitch").path)
    }

    /// Copy first, then atomically replace on the destination volume. The source
    /// remains intact, and an explicitly replaced app is retained as a backup.
    @discardableResult
    func copy(from source: URL, to destination: URL, replaceExisting: Bool = false) throws -> URL? {
        guard isFlipBundle(source) else { throw ApplicationInstallationError.invalidBundle }
        let symbolic = (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        if symbolic { throw ApplicationInstallationError.destinationOccupied }
        if source.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath() {
            return nil
        }
        let existing = fileManager.fileExists(atPath: destination.path)
        if existing {
            guard isFlipBundle(destination) else { throw ApplicationInstallationError.destinationOccupied }
            guard replaceExisting else { throw ApplicationInstallationError.replacementNotApproved }
        }
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".flip-install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: staging) }
        let stagedApp = staging.appendingPathComponent("Flip.app", isDirectory: true)
        try fileManager.copyItem(at: source, to: stagedApp)
        guard isFlipBundle(stagedApp) else { throw ApplicationInstallationError.invalidBundle }
        if existing {
            let backupName = ".Flip.previous-\(UUID().uuidString).app"
            _ = try fileManager.replaceItemAt(destination, withItemAt: stagedApp, backupItemName: backupName,
                                              options: [.withoutDeletingBackupItem])
            return parent.appendingPathComponent(backupName)
        }
        try fileManager.moveItem(at: stagedApp, to: destination)
        return nil
    }

    /// Retarget only a shortcut that belongs to the source app. Other commands,
    /// regular files, and absent optional CLI installations are left alone.
    @discardableResult
    func retargetCLI(at command: URL, from source: URL, to installed: URL) throws -> Bool {
        guard isFlipBundle(installed), info(at: installed)?["FlipControlProtocolVersion"] as? Int == 1,
              let target = try? fileManager.destinationOfSymbolicLink(atPath: command.path) else { return false }
        let current = URL(fileURLWithPath: target, relativeTo: command.deletingLastPathComponent())
            .standardizedFileURL.resolvingSymlinksInPath()
        let sourceExecutable = source.appendingPathComponent("Contents/MacOS/DNSSwitch")
            .standardizedFileURL.resolvingSymlinksInPath()
        guard current == sourceExecutable else { return false }
        let temporary = command.deletingLastPathComponent().appendingPathComponent(".flip-link-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.createSymbolicLink(at: temporary,
                                          withDestinationURL: installed.appendingPathComponent("Contents/MacOS/DNSSwitch"))
        guard rename(temporary.path, command.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "The existing flip command could not be updated."])
        }
        return true
    }
}
