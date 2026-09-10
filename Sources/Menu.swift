import AppKit
import ServiceManagement

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AwakeModel()
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var statusLine: NSMenuItem?
    var outcomeLine: NSMenuItem?
    var powerLine: NSMenuItem?
    var actionItem: NSMenuItem?
    var quitPending = false
    var lastShownError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.identifier).count > 1 {
            NSApp.terminate(nil); return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.autoenablesItems = false
        menu.minimumWidth = 286
        menu.delegate = self
        statusItem.button?.target = self
        statusItem.button?.action = #selector(showMenu)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        model.onUpdate = { [weak self] in self?.updateStatus() }
        model.onStopped = { [weak self] in
            guard let self, self.quitPending else { return }
            self.completeQuit()
        }
        updateStatus()
        if !UserDefaults.standard.bool(forKey: "hasLaunchedNativeMenu") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedNativeMenu")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showMenu() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        image?.isTemplate = true
        return image
    }

    @discardableResult private func item(_ title: String, action: Selector? = nil, key: String = "", enabled: Bool = true, image: String? = nil, into target: NSMenu? = nil) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: key)
        row.target = self
        row.isEnabled = enabled
        if let image { row.image = symbol(image) }
        (target ?? menu).addItem(row)
        return row
    }

    private func checked(_ title: String, value: Bool, action: Selector, enabled: Bool = true, into target: NSMenu? = nil) {
        item(title, action: action, enabled: enabled, into: target).state = value ? .on : .off
    }

    var durationTitle: String {
        if model.duration == 0 { return "Until stopped" }
        if model.duration == -1 { return "\(model.customMinutes) minutes" }
        if model.duration < 60 { return "\(model.duration) minutes" }
        return "\(model.duration / 60) \(model.duration == 60 ? "hour" : "hours")"
    }

    func rebuildMenu() {
        model.refreshLogin()
        menu.removeAllItems()
        menu.addItem(NSMenuItem.sectionHeader(title: "Keep Awake"))
        statusLine = item("", enabled: false, image: model.isRunning ? "cup.and.saucer.fill" : "cup.and.saucer")
        outcomeLine = item("", enabled: false)
        powerLine = item(model.power.description, enabled: false, image: model.power.onAC == true ? "powerplug" : "battery.75percent")
        menu.addItem(.separator())

        if model.needsRecovery {
            item("Restore normal sleep…", action: #selector(recover), enabled: !model.isBusy, image: "exclamationmark.triangle")
        }
        actionItem = item("", action: #selector(toggleSession), key: "s")
        let duration = item("Duration: \(durationTitle)", enabled: !model.isBusy)
        let durations = NSMenu()
        durations.autoenablesItems = false
        for minutes in [15, 30, 60, 120, 240, 480] {
            let title = minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) \(minutes == 60 ? "hour" : "hours")"
            let row = item(title, action: #selector(setDuration(_:)), into: durations)
            row.tag = minutes; row.state = model.duration == minutes ? .on : .off
        }
        durations.addItem(.separator())
        let indefinite = item("Until stopped", action: #selector(setDuration(_:)), into: durations)
        indefinite.tag = 0; indefinite.state = model.duration == 0 ? .on : .off
        let custom = item("Custom…", action: #selector(customDuration), into: durations)
        custom.state = model.duration == -1 ? .on : .off
        duration.submenu = durations
        menu.addItem(.separator())

        checked("Keep awake with lid closed", value: model.mode == .closedLid, action: #selector(toggleLid), enabled: !model.isBusy)
        menu.items.last?.toolTip = "Closed-lid sessions require administrator approval. Standard sessions prevent idle sleep only."
        checked("Only while plugged in", value: model.chargerOnly, action: #selector(toggleCharger), enabled: !model.isBusy)
        checked("Keep display on", value: model.keepDisplayOn && model.mode == .ordinary, action: #selector(toggleDisplay), enabled: !model.isBusy && model.mode == .ordinary)
        if !model.chargerOnly {
            let cutoff = item("Battery cutoff: \(model.batteryFloor)%", enabled: !model.isBusy)
            let cutoffs = NSMenu()
            cutoffs.autoenablesItems = false
            for value in [10, 20, 30, 40, 50] {
                let row = item("\(value)%", action: #selector(setCutoff(_:)), into: cutoffs)
                row.tag = value; row.state = model.batteryFloor == value ? .on : .off
            }
            cutoff.submenu = cutoffs
        }
        menu.addItem(.separator())

        let settings = item("Settings")
        let preferences = NSMenu()
        preferences.autoenablesItems = false
        checked("Show countdown in menu bar", value: model.showCountdown, action: #selector(toggleCountdown), into: preferences)
        checked("Launch at login", value: model.loginEnabled, action: #selector(toggleLogin), into: preferences)
        if model.loginNeedsApproval { item("Approve in Login Items…", action: #selector(openLoginSettings), into: preferences) }
        preferences.addItem(.separator())
        item("About Keep Awake", action: #selector(about), into: preferences)
        settings.submenu = preferences
        item("Session details…", action: #selector(sessionDetails))
        item("Copy diagnostics", action: #selector(copyDiagnostics))
        item("User guide", action: #selector(help))
        item("Quit Keep Awake", action: #selector(quit), key: "q")
        updateStatus()
    }

    func updateStatus() {
        guard let button = statusItem?.button else { return }
        let image = NSImage(systemSymbolName: model.isRunning ? "cup.and.saucer.fill" : "cup.and.saucer", accessibilityDescription: "Keep Awake")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        button.title = model.isRunning && model.showCountdown ? " " + (model.remaining == nil ? "∞" : model.countdown) : ""
        button.toolTip = "Keep Awake · \(model.statusTitle)"
        button.setAccessibilityLabel("Keep Awake")
        button.setAccessibilityValue(model.statusTitle + (model.isRunning ? ", " + model.countdown : ""))
        statusLine?.title = model.isRunning ? "\(model.countdown)\(model.remaining == nil ? "" : " remaining")" : model.statusTitle
        statusLine?.toolTip = model.message
        let outcome = model.message.replacingOccurrences(of: "\n", with: " ")
        outcomeLine?.title = outcome.count > 64 ? String(outcome.prefix(63)) + "…" : outcome
        outcomeLine?.setAccessibilityLabel(model.message)
        powerLine?.title = model.power.description
        actionItem?.title = model.isRunning ? "Stop session" : model.phase == .starting ? "Waiting for approval…" : model.phase == .stopping ? "Restoring normal sleep…" : "Start session"
        actionItem?.isEnabled = model.phase == .idle || model.phase == .running
        if model.needsRecovery && model.mode == .closedLid && model.phase == .idle { actionItem?.isEnabled = false }
        if let error = model.errorMessage, lastShownError != error {
            lastShownError = error
            if error != "Administrator approval was cancelled." {
                DispatchQueue.main.async { [weak self] in self?.presentError(error) }
            }
        }
        if model.errorMessage == nil { lastShownError = nil }
    }

    private func presentError(_ message: String) {
        menu.cancelTracking()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Keep Awake couldn't complete the request"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func toggleSession() { if model.isRunning { model.stop() } else { model.start() } }
    @objc func setDuration(_ sender: NSMenuItem) { model.duration = sender.tag }
    @objc func toggleLid() { model.mode = model.mode == .closedLid ? .ordinary : .closedLid }
    @objc func toggleCharger() { model.chargerOnly.toggle() }
    @objc func toggleDisplay() { model.keepDisplayOn.toggle() }
    @objc func toggleCountdown() { model.showCountdown.toggle() }
    @objc func toggleLogin() { model.setLogin(!model.loginEnabled) }
    @objc func setCutoff(_ sender: NSMenuItem) { model.batteryFloor = sender.tag }
    @objc func recover() { model.recover() }
    @objc func sessionDetails() {
        menu.cancelTracking()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = model.statusTitle
        alert.informativeText = [model.message, model.errorMessage == model.message ? nil : model.errorMessage]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Copy diagnostics")
        if alert.runModal() == .alertSecondButtonReturn { copyDiagnostics() }
    }
    @objc func copyDiagnostics() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        // Keep this an allowlist: raw authorization errors can contain local paths.
        let report = """
        Keep Awake \(AppInfo.version)
        macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)
        State: \(model.statusTitle)
        Selected mode: \(model.mode.rawValue)
        Duration: \(durationTitle)
        Power: \(model.power.description)
        Charger only: \(model.chargerOnly)
        Battery cutoff: \(model.batteryFloor)%
        Recovery offered: \(model.needsRecovery)
        Error: \(model.errorMessage == nil ? "none" : "present; see Session details")
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
    @objc func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc func about() { NSApp.activate(ignoringOtherApps: true); NSApp.orderFrontStandardAboutPanel(nil) }
    @objc func help() {
        if let url = Bundle.main.url(forResource: "Help", withExtension: "html") { NSWorkspace.shared.open(url) }
    }
    @objc func customDuration() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Custom duration"
        alert.informativeText = "Enter a duration from 1 to 1,440 minutes."
        alert.addButton(withTitle: "Set duration")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(string: model.duration == -1 ? model.customMinutes : String(max(1, model.duration)))
        input.frame = NSRect(x: 0, y: 0, width: 230, height: 24)
        input.setAccessibilityLabel("Duration in minutes")
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let value = Int(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), (1...1440).contains(value) else {
            presentError("Enter a whole number from 1 to 1,440 minutes."); return
        }
        model.customMinutes = String(value)
        model.duration = -1
    }
    @objc func showMenu() {
        guard let button = statusItem.button, let window = button.window else { return }
        rebuildMenu()
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: frame.minY - 4), in: nil)
    }
    @objc func quit() { menu.cancelTracking(); NSApp.terminate(nil) }
    private func completeQuit() {
        guard quitPending else { return }
        quitPending = false
        model.prepareToQuit()
        NSApp.reply(toApplicationShouldTerminate: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMenu(); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.phase == .starting {
            presentError("Approve or cancel the administrator prompt, then quit Keep Awake.")
            return .terminateCancel
        }
        if model.isRunning || model.phase == .stopping {
            if model.isRunning { model.stop() }
            if model.phase == .idle { model.prepareToQuit(); return .terminateNow }
            quitPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self, self.quitPending, self.model.phase != .idle else { return }
                self.completeQuit()
            }
            return .terminateLater
        }
        model.prepareToQuit(); return .terminateNow
    }
}

@main struct KeepAwakeMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
