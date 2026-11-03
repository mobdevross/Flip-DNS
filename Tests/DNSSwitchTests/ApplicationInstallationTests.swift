import Foundation
import XCTest
@testable import DNSSwitch

private final class FailingCopyManager: FileManager, @unchecked Sendable {
    override func copyItem(at source: URL, to destination: URL) throws {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    }
}

final class ApplicationInstallationTests: XCTestCase {
    private let files = FileManager.default

    func testLocationCheckAcceptsOnlyRealApplicationsRoots() throws {
        let root = try workspace()
        defer { try? files.removeItem(at: root) }
        let system = root.appendingPathComponent("Applications")
        let user = root.appendingPathComponent("Home/Applications")
        let roots = [system, user]
        XCTAssertTrue(ApplicationInstallation.isInstalled(system.appendingPathComponent("Flip.app"), in: roots))
        XCTAssertTrue(ApplicationInstallation.isInstalled(system.appendingPathComponent("Utilities/Flip.app"), in: roots))
        XCTAssertTrue(ApplicationInstallation.isInstalled(user.appendingPathComponent("Flip.app"), in: roots))
        XCTAssertFalse(ApplicationInstallation.isInstalled(root.appendingPathComponent("Applications-backup/Flip.app"), in: roots))
        XCTAssertFalse(ApplicationInstallation.isInstalled(root.appendingPathComponent("Downloads/Applications/Flip.app"), in: roots))
        XCTAssertFalse(ApplicationInstallation.isInstalled(system, in: roots))
    }

    func testCopyPreservesTheSourceAndCreatesACompleteInstalledBundle() throws {
        let root = try workspace()
        defer { try? files.removeItem(at: root) }
        let source = try bundle(at: root.appendingPathComponent("Downloads/Flip.app"), marker: "new")
        let destination = root.appendingPathComponent("Applications/Flip.app")
        let installer = ApplicationInstallation()
        XCTAssertNil(try installer.copy(from: source, to: destination))
        XCTAssertTrue(installer.isFlipBundle(destination))
        XCTAssertEqual(try marker(at: source), "new")
        try Data("changed installed copy".utf8).write(to: destination.appendingPathComponent("Contents/marker.txt"))
        XCTAssertEqual(try marker(at: source), "new")
    }

    func testReplacingAnInstalledCopyRequiresApproval() throws {
        let root = try workspace()
        defer { try? files.removeItem(at: root) }
        let source = try bundle(at: root.appendingPathComponent("Downloads/Flip.app"), marker: "new")
        let destination = try bundle(at: root.appendingPathComponent("Applications/Flip.app"), marker: "old")
        XCTAssertThrowsError(try ApplicationInstallation().copy(from: source, to: destination)) { error in
            guard case ApplicationInstallationError.replacementNotApproved = error else {
                return XCTFail("Expected an explicit replacement decision")
            }
        }
        XCTAssertEqual(try marker(at: destination), "old")
    }

    func testApprovedReplacementKeepsARecoverableBackup() throws {
        let root = try workspace()
        defer { try? files.removeItem(at: root) }
        let source = try bundle(at: root.appendingPathComponent("Downloads/Flip.app"), marker: "new")
        let destination = try bundle(at: root.appendingPathComponent("Applications/Flip.app"), marker: "old")
        let backup = try XCTUnwrap(ApplicationInstallation().copy(from: source, to: destination, replaceExisting: true))
        XCTAssertEqual(try marker(at: destination), "new")
        XCTAssertEqual(try marker(at: backup), "old")
        XCTAssertEqual(try marker(at: source), "new")
        XCTAssertTrue(backup.lastPathComponent.hasPrefix(".Flip.previous-"))
    }

    func testAnotherApplicationIsNeverReplaced() throws {
        let root = try workspace()
        defer { try? files.removeItem(at: root) }
        let source = try bundle(at: root.appendingPathComponent("Downloads/Flip.app"), marker: "new")
        let destination = try bundle(at: root.appendingPathComponent("Applications/Flip.app"), marker: "unrelated",
                                     identifier: "com.example.another-app")
        XCTAssertThrowsError(try ApplicationInstallation().copy(from: source, to: destination, replaceExisting: true))
        XCTAssertEqual(try marker(at: destination), "unrelated")
    }

    func testDestinationSymlinksAreNotFollowedOrReplaced() throws {
        let root = try workspace()
        defer { try? files.removeItem(at: root) }
        let source = try bundle(at: root.appendingPathComponent("Downloads/Flip.app"), marker: "new")
        let destination = root.appendingPathComponent("Applications/Flip.app")
        try files.createSymbolicLink(at: destination, withDestinationURL: source)
        XCTAssertThrowsError(try ApplicationInstallation().copy(from: source, to: destination, replaceExisting: true))
        XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: destination.path), source.path)
        XCTAssertEqual(try marker(at: source), "new")
    }

    func testCopyFailurePreservesTheExistingApplicationAndRemovesStagingFiles() throws {
        let root = try workspace()
        defer { try? files.removeItem(at: root) }
        let source = try bundle(at: root.appendingPathComponent("Downloads/Flip.app"), marker: "new")
        let destination = try bundle(at: root.appendingPathComponent("Applications/Flip.app"), marker: "old")
        XCTAssertThrowsError(try ApplicationInstallation(fileManager: FailingCopyManager())
            .copy(from: source, to: destination, replaceExisting: true))
        XCTAssertEqual(try marker(at: destination), "old")
        XCTAssertEqual(try files.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["Flip.app"])
    }

    func testExistingSourceShortcutFollowsTheInstalledCopy() throws {
        let root = try workspace()
        defer { try? files.removeItem(at: root) }
        let source = try bundle(at: root.appendingPathComponent("Downloads/Flip.app"), marker: "new")
        let destination = root.appendingPathComponent("Applications/Flip.app")
        let installer = ApplicationInstallation()
        try installer.copy(from: source, to: destination)
        let command = root.appendingPathComponent("bin/flip")
        try files.createSymbolicLink(at: command, withDestinationURL: source.appendingPathComponent("Contents/MacOS/DNSSwitch"))
        XCTAssertTrue(try installer.retargetCLI(at: command, from: source, to: destination))
        XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: command.path),
                       destination.appendingPathComponent("Contents/MacOS/DNSSwitch").path)
        XCTAssertTrue(files.isExecutableFile(atPath: command.path))
    }

    func testRelativeSourceShortcutIsRecognized() throws {
        let root = try workspace()
        defer { try? files.removeItem(at: root) }
        let source = try bundle(at: root.appendingPathComponent("Downloads/Flip.app"), marker: "new")
        let destination = root.appendingPathComponent("Applications/Flip.app")
        let installer = ApplicationInstallation()
        try installer.copy(from: source, to: destination)
        let command = root.appendingPathComponent("bin/flip")
        try files.createSymbolicLink(atPath: command.path, withDestinationPath: "../Downloads/Flip.app/Contents/MacOS/DNSSwitch")
        XCTAssertTrue(try installer.retargetCLI(at: command, from: source, to: destination))
    }

    func testMissingAndUnrelatedCommandsAreLeftAlone() throws {
        let root = try workspace()
        defer { try? files.removeItem(at: root) }
        let source = try bundle(at: root.appendingPathComponent("Downloads/Flip.app"), marker: "new")
        let destination = root.appendingPathComponent("Applications/Flip.app")
        let installer = ApplicationInstallation()
        try installer.copy(from: source, to: destination)
        let command = root.appendingPathComponent("bin/flip")
        XCTAssertFalse(try installer.retargetCLI(at: command, from: source, to: destination))
        XCTAssertFalse(files.fileExists(atPath: command.path))
        try Data("another command".utf8).write(to: command)
        XCTAssertFalse(try installer.retargetCLI(at: command, from: source, to: destination))
        XCTAssertEqual(try String(contentsOf: command), "another command")
        try files.removeItem(at: command)
        let other = root.appendingPathComponent("another-tool")
        try Data("keep me".utf8).write(to: other)
        try files.createSymbolicLink(at: command, withDestinationURL: other)
        XCTAssertFalse(try installer.retargetCLI(at: command, from: source, to: destination))
        XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: command.path), other.path)
    }

    private func workspace() throws -> URL {
        let root = files.temporaryDirectory.appendingPathComponent("flip-install-test-\(UUID().uuidString)")
        for directory in ["Downloads", "Applications", "bin"] {
            try files.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        return root
    }

    @discardableResult
    private func bundle(at url: URL, marker: String,
                        identifier: String = ApplicationInstallation.identifier) throws -> URL {
        let executable = url.appendingPathComponent("Contents/MacOS/DNSSwitch")
        try files.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test executable".utf8).write(to: executable)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let metadata: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "DNSSwitch",
            "CFBundlePackageType": "APPL", "FlipControlProtocolVersion": 1,
        ]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(marker.utf8).write(to: url.appendingPathComponent("Contents/marker.txt"))
        return url
    }

    private func marker(at bundle: URL) throws -> String {
        try String(contentsOf: bundle.appendingPathComponent("Contents/marker.txt"))
    }
}
