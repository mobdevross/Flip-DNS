import AppKit

@MainActor
struct ApplicationLocationPrompt {
    private let installer = ApplicationInstallation()
    private let destination = URL(fileURLWithPath: "/Applications/Flip.app", isDirectory: true)

    /// Return false only after successfully handing off to the installed copy.
    /// This runs before the source app starts timers or its control bridge.
    func continueFromCurrentLocation() async -> Bool {
        let source = Bundle.main.bundleURL
        guard source.pathExtension.lowercased() == "app",
              !ApplicationInstallation.isInstalled(source) else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let exists = FileManager.default.fileExists(atPath: destination.path)
        if exists, !installer.isFlipBundle(destination) {
            showError("Applications already contains another item named Flip.app. Move or rename it in Finder to install Flip here.")
            return true
        }
        if installedCopyIsRunning {
            let alert = NSAlert()
            alert.messageText = "Flip is already running from Applications"
            alert.informativeText = "Open that copy, or quit it before installing this build."
            alert.addButton(withTitle: "Open Installed Flip")
            alert.addButton(withTitle: "Not Now")
            guard alert.runModal() == .alertFirstButtonReturn else { return true }
            return await openInstalledCopy(replacing: source)
        }

        let alert = NSAlert()
        alert.messageText = exists ? "Update Flip in Applications?" : "Copy Flip to Applications?"
        alert.informativeText = exists
            ? "Replace the installed copy with this build and open it from Applications? The previous copy will be kept as a hidden backup."
            : "Copy Flip into your Applications folder and open it from there. This gives it a stable home for Launch at Login and the command-line shortcut."
        alert.addButton(withTitle: exists ? "Replace and Open" : "Copy and Open")
        if exists { alert.addButton(withTitle: "Open Installed Copy") }
        alert.addButton(withTitle: "Not Now")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do {
                guard !installedCopyIsRunning else {
                    showError("Quit the installed copy of Flip before replacing it.")
                    return true
                }
                try installer.copy(from: source, to: destination, replaceExisting: exists)
                return await openInstalledCopy(replacing: source)
            } catch {
                showError("Flip could not be copied to Applications. You can copy it there in Finder or continue from this location.\n\n\(error.localizedDescription)")
                return true
            }
        case .alertSecondButtonReturn where exists:
            return await openInstalledCopy(replacing: source)
        default:
            return true
        }
    }

    private var installedCopyIsRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: ApplicationInstallation.identifier).contains {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath()
        }
    }

    private func openInstalledCopy(replacing source: URL) async -> Bool {
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = !installedCopyIsRunning
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { application, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let application, application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: NSError(domain: "Flip.Installation", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "The installed copy did not start."]))
                    }
                }
            }
            do {
                let command = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/flip")
                try installer.retargetCLI(at: command, from: source, to: destination)
            } catch {
                showError("Flip is installed, but the existing command-line shortcut could not be updated. Re-run the CLI installer for /Applications/Flip.app.\n\n\(error.localizedDescription)")
            }
            return false
        } catch {
            showError("Flip is in Applications but could not be opened. You can open it from Finder; this copy will keep running.\n\n\(error.localizedDescription)")
            return true
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Flip"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
