import AppKit
import Combine
import DNSCore
import FlipAutomation
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = SwitcherModel(backend: SystemDNSBackend(), storage: DefaultsBypassStorage())
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var observer: NetworkObserver?
    private var controlServer: ControlServer?
    private var tick: Timer?
    private var debounce: DispatchWorkItem?
    private var subscriptions: Set<AnyCancellable> = []
    private var canTerminate = false
    private var timerMenuItem: NSMenuItem?
    private var renderedState: MenuState?
    private var renderedIcon: StatusIcon.Style?

    private struct MenuState: Equatable {
        let mode: DNSMode
        let isBusy: Bool
        let canChange: Bool
        let bypass: TimedBypass?
        let error: String?
        let information: String?
        let loginStatus: Int
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.imagePosition = .imageOnly
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        model.objectWillChange.sink { [weak self] in
            // Published values change after this notification.
            DispatchQueue.main.async { self?.render() }
        }.store(in: &subscriptions)

        observer = NetworkObserver()
        observer?.onChange = { [weak self] in self?.scheduleRefresh() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        let controlService = ControlService(model: model)
        do {
            controlServer = try ControlServer { request, reply in
                Task { @MainActor in reply(await controlService.handle(request)) }
            }
        } catch {
            NSLog("Flip CLI control could not start: %@", error.localizedDescription)
        }
        render()
        Task {
            await model.refresh()
            await model.checkDeadline()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        render()
        Task { await model.refresh() }
    }

    private func render() {
        guard statusItem != nil else { return }
        updateCountdownTimer()
        let pending = model.bypass?.restorePending == true
        let icon: StatusIcon.Style
        if model.isBusy { icon = .busy }
        else if pending || model.errorMessage != nil { icon = .attention }
        else if model.mode == .unavailable { icon = .unknown }
        else if model.bypass != nil { icon = .timed }
        else { icon = model.mode == .automatic ? .automatic : .bypass }
        if icon != renderedIcon {
            statusItem.button?.image = StatusIcon.image(for: icon)
            renderedIcon = icon
        }
        statusItem.button?.title = ""
        statusItem.button?.setAccessibilityLabel("Flip: \(model.isBusy ? "Changing DNS" : model.mode.rawValue)\(pending ? ", restore pending" : "")")
        statusItem.button?.toolTip = ["Flip — \(model.mode.rawValue)", timerDescription(), model.errorMessage]
            .compactMap { $0 }.joined(separator: "\n")

        // Updating the countdown must not rebuild an open menu every second:
        // doing so would interrupt selection of the duration submenu.
        if let timerText = timerDescription() { timerMenuItem?.title = timerText }
        let canChange = !model.isBusy && model.isReadable && !model.eligibleServices.isEmpty
        let state = MenuState(mode: model.mode, isBusy: model.isBusy,
                              canChange: canChange, bypass: model.bypass,
                              error: model.errorMessage, information: model.information,
                              loginStatus: SMAppService.mainApp.status.rawValue)
        guard state != renderedState else { return }
        renderedState = state

        menu.removeAllItems()
        timerMenuItem = nil
        addText(model.isBusy ? "Changing DNS — waiting for macOS…" : "DNS: \(model.mode.rawValue)")
        if let timerText = timerDescription() { timerMenuItem = addText(timerText) }
        if let error = model.errorMessage { addText(error, prefix: "Error: ") }
        if let information = model.information { addText(information) }
        menu.addItem(.separator())

        let automatic = addAction("Automatic", #selector(selectAutomatic), enabled: canChange)
        automatic.state = model.mode == .automatic ? .on : .off
        let publicDNS = addAction("Public DNS", #selector(selectPublic), enabled: canChange)
        publicDNS.state = model.mode == .publicDNS ? .on : .off
        let timed = NSMenuItem(title: "Public DNS for…", action: nil, keyEquivalent: "")
        let durations = NSMenu()
        durations.autoenablesItems = false
        for minutes in [5, 15, 60] {
            let item = NSMenuItem(title: "\(minutes) minutes", action: #selector(selectTimed(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            item.isEnabled = canChange
            durations.addItem(item)
        }
        timed.submenu = durations
        timed.isEnabled = canChange
        menu.addItem(timed)
        if model.bypass != nil {
            addAction(pending ? "Restore Automatic Now…" : "End Timed Bypass Now",
                      #selector(restoreTimed), enabled: !model.isBusy)
        }

        menu.addItem(.separator())
        let loginService = SMAppService.mainApp
        let loginTitle = loginService.status == .requiresApproval ? "Approve Launch at Login…" : "Launch at Login"
        let login = addAction(loginTitle, #selector(toggleLogin))
        login.state = loginService.status == .enabled ? .on : .off
        menu.addItem(.separator())
        addAction("About Flip", #selector(showAbout))
        addAction("Quit Flip", #selector(requestQuit), enabled: !model.isBusy, key: "q")
    }

    private func updateCountdownTimer() {
        let needsCountdown = model.bypass.map { !$0.restorePending } ?? false
        guard needsCountdown else {
            tick?.invalidate()
            tick = nil
            return
        }
        guard tick == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.render()
                Task { await self.model.checkDeadline() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func timerDescription() -> String? {
        guard let bypass = model.bypass else { return nil }
        if bypass.restorePending { return "Restore pending — approval or retry needed" }
        let seconds = max(0, Int(ceil(bypass.deadline.timeIntervalSinceNow)))
        if seconds == 0 { return "Returning to Automatic…" }
        return "Return to Automatic in \(seconds / 60)m \(seconds % 60)s"
    }

    @discardableResult
    private func addText(_ text: String, prefix: String = "") -> NSMenuItem {
        let complete = prefix + text
        let item = NSMenuItem(title: complete.count > 105 ? String(complete.prefix(102)) + "…" : complete,
                              action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = complete
        menu.addItem(item)
        return item
    }

    @discardableResult
    private func addAction(_ title: String, _ action: Selector, enabled: Bool = true,
                           key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    @objc private func selectAutomatic() { Task { await model.choose(.automatic) } }
    @objc private func selectPublic() { Task { await model.choose(.publicDNS) } }
    @objc private func selectTimed(_ sender: NSMenuItem) {
        Task { await model.choose(.publicDNS, minutes: sender.tag) }
    }
    @objc private func restoreTimed() { Task { await model.restoreTimedBypass() } }

    private func scheduleRefresh() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self.model.refresh() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    @objc private func wokeUp() {
        Task {
            await model.refresh()
            await model.checkDeadline()
        }
    }

    @objc private func becameActive() { wokeUp() }

    @objc private func toggleLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                Task {
                    do { try await SMAppService.mainApp.unregister() }
                    catch { showError(error.localizedDescription) }
                    render()
                }
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch { showError(error.localizedDescription) }
        render()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Flip",
            .applicationVersion: "1.2.0",
            .credits: NSAttributedString(string: "Switch Wi-Fi and Ethernet between network-provided DNS and Cloudflare public DNS.\n\nTimed restoration requires this app to be running and may need macOS administrator approval."),
        ])
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Flip"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func requestQuit() {
        guard !model.isBusy else { NSSound.beep(); return }
        guard model.bypass != nil else { terminate(); return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "A timed DNS bypass is active"
        alert.informativeText = "Flip must stay running to restore Automatic when the timer ends. What would you like to do?"
        alert.addButton(withTitle: "Restore Automatic and Quit")
        alert.addButton(withTitle: "Keep Public DNS and Quit")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                if await model.restoreTimedBypass() { terminate() }
                else { showError(model.errorMessage ?? "Automatic DNS could not be restored. The app will stay open.") }
            }
        case .alertSecondButtonReturn:
            model.abandonTimer()
            terminate()
        default: break
        }
    }

    private func terminate() {
        canTerminate = true
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if canTerminate { return .terminateNow }
        // Avoid nested termination inside the delegate callback.
        DispatchQueue.main.async { [weak self] in self?.requestQuit() }
        return .terminateCancel
    }
}
