import AppKit
import Combine
import ServiceManagement
import IOKit.pwr_mgt

enum Phase { case idle, starting, running, stopping }

@MainActor final class AwakeModel: ObservableObject {
    @Published var mode: SessionMode = .ordinary { didSet { persist() } }
    @Published var duration = 60 { didSet { persist() } }
    @Published var customMinutes = "60" { didSet { persist() } }
    @Published var chargerOnly = true { didSet { persist() } }
    @Published var batteryFloor = 20 { didSet { persist() } }
    @Published var keepDisplayOn = false { didSet { persist() } }
    @Published var showCountdown = true { didSet { persist() } }
    @Published var phase: Phase = .idle
    @Published var power = PowerSnapshot.current()
    @Published var remaining: TimeInterval?
    @Published var message = "Ready when you are"
    @Published var errorMessage: String?
    @Published var needsRecovery = false
    @Published var loginEnabled = false
    @Published var loginNeedsApproval = false
    var onUpdate: (() -> Void)?
    var onStopped: (() -> Void)?
    private var timer: Timer?
    private var activeOptions: SessionOptions?
    private var startedUptime: TimeInterval = 0
    private var assertions: [IOPMAssertionID] = []
    private var leaseURL: URL?
    private var sessionID: String?
    private var stoppingSince: Date?
    private var loaded = false

    init() {
        let prefs = UserDefaults.standard
        mode = SessionMode(rawValue: prefs.string(forKey: "mode") ?? "ordinary") ?? .ordinary
        duration = prefs.object(forKey: "duration") as? Int ?? 60
        customMinutes = prefs.string(forKey: "customMinutes") ?? "60"
        chargerOnly = prefs.object(forKey: "chargerOnly") as? Bool ?? true
        batteryFloor = prefs.object(forKey: "batteryFloor") as? Int ?? 20
        keepDisplayOn = prefs.bool(forKey: "keepDisplayOn")
        showCountdown = prefs.object(forKey: "showCountdown") as? Bool ?? true
        loaded = true
        refreshLogin()
        refreshRecovery()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func persist() {
        guard loaded else { return }
        if phase == .idle { errorMessage = nil }
        let prefs = UserDefaults.standard
        prefs.set(mode.rawValue, forKey: "mode")
        prefs.set(duration, forKey: "duration")
        prefs.set(customMinutes, forKey: "customMinutes")
        prefs.set(chargerOnly, forKey: "chargerOnly")
        prefs.set(batteryFloor, forKey: "batteryFloor")
        prefs.set(keepDisplayOn, forKey: "keepDisplayOn")
        prefs.set(showCountdown, forKey: "showCountdown")
        onUpdate?()
    }

    var isBusy: Bool { phase != .idle }
    var isRunning: Bool { phase == .running }
    var statusTitle: String {
        switch phase {
        case .idle: return needsRecovery ? "Sleep needs restoring" : "Ready"
        case .starting: return "Starting session…"
        case .running: return activeOptions?.mode == .closedLid ? "Awake with lid closed" : "Keeping your Mac awake"
        case .stopping: return "Restoring normal sleep…"
        }
    }
    var countdown: String {
        guard let remaining else { return "Until stopped" }
        let seconds = max(0, Int(remaining.rounded(.up)))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func options() throws -> SessionOptions {
        guard let minutes = duration == -1 ? Int(customMinutes.trimmingCharacters(in: .whitespacesAndNewlines)) : duration else {
            throw AwakeError("Enter a whole number of minutes.")
        }
        if duration == -1 && minutes == 0 { throw AwakeError("Enter at least one minute, or choose Until stopped.") }
        let result = SessionOptions(mode: mode, minutes: minutes, chargerOnly: chargerOnly, batteryFloor: batteryFloor, keepDisplayOn: mode == .ordinary && keepDisplayOn)
        try result.validate()
        return result
    }

    func start() {
        guard phase == .idle else { return }
        errorMessage = nil
        do {
            let options = try options()
            power = .current()
            if let reason = SessionPolicy.stopReason(options: options, power: power, elapsed: 0) { throw AwakeError(reason) }
            if options.mode == .closedLid {
                guard !needsRecovery else { throw AwakeError("Restore normal sleep before starting another closed-lid session.") }
                try startClosedLid(options)
            } else {
                try takeAssertion(kIOPMAssertionTypePreventUserIdleSystemSleep)
                if options.keepDisplayOn { try takeAssertion(kIOPMAssertionTypePreventUserIdleDisplaySleep) }
                activate(options)
            }
        } catch {
            releaseAssertions()
            errorMessage = error.localizedDescription
        }
        onUpdate?()
    }

    private func takeAssertion(_ type: String) throws {
        var id: IOPMAssertionID = 0
        let code = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Keep Awake session" as CFString, &id)
        guard code == kIOReturnSuccess else { throw AwakeError("macOS could not start sleep prevention. Error \(code).") }
        assertions.append(id)
    }

    private func activate(_ options: SessionOptions) {
        activeOptions = options
        startedUptime = ProcessInfo.processInfo.systemUptime
        remaining = options.minutes == 0 ? nil : Double(options.minutes * 60)
        phase = .running
        message = options.chargerOnly ? "Ends when you unplug the charger" : "Stops at \(options.batteryFloor)% battery"
    }

    private func startClosedLid(_ options: SessionOptions) throws {
        guard let parent = ProcessIdentity.read(getpid()) else { throw AwakeError("The app could not identify this session.") }
        let id = UUID().uuidString
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(AppInfo.identifier, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(id + ".json")
        leaseURL = url; sessionID = id
        try writeLease(active: true)
        let request = HelperRequest(sessionID: id, parent: parent, leasePath: url.path, options: options)
        let payload = try JSONEncoder().encode(request).base64EncodedString()
        activeOptions = options
        phase = .starting
        message = "Approve the macOS administrator prompt to begin"
        authorize(arguments: ["--launch", payload]) { [weak self] error in
            guard let self else { return }
            if let error {
                try? self.writeLease(active: false)
                if let state = HelperStatus.read(), state.sessionID == id, state.needsRestore, !state.helper.hasExited {
                    self.phase = .stopping; self.stoppingSince = Date()
                } else { self.finish(reason: "Session did not start") }
                self.errorMessage = error
            } else if let state = HelperStatus.read(), state.sessionID == id, state.state == "running" {
                self.activate(options)
            } else {
                self.finish(reason: HelperStatus.read()?.reason ?? "Session ended before it could start")
            }
            self.refreshRecovery()
            self.onUpdate?()
        }
    }

    private func authorize(arguments: [String], completion: @escaping (String?) -> Void) {
        guard let helper = Bundle.main.url(forResource: "KeepAwakeHelper", withExtension: nil) else {
            completion("The app is missing its session helper. Install a fresh copy."); return
        }
        func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = ([helper.path] + arguments).map(shellQuote).joined(separator: " ")
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(literal)\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            let result: String?
            if let error {
                let number = error[NSAppleScript.errorNumber] as? Int
                result = number == -128 ? "Administrator approval was cancelled." : (error[NSAppleScript.errorMessage] as? String ?? "Administrator approval failed.")
            } else { result = nil }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func writeLease(active: Bool) throws {
        guard let url = leaseURL, let id = sessionID else { return }
        let data = try JSONEncoder().encode(Lease(sessionID: id, active: active, updated: Date()))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func stop(reason: String = "Stopped") {
        guard phase == .running else { return }
        if activeOptions?.mode == .closedLid {
            do { try writeLease(active: false) }
            catch { errorMessage = "The stop request could not be saved. The helper will stop when the app exits or its heartbeat expires." }
            phase = .stopping
            stoppingSince = Date()
        } else { finish(reason: reason) }
        onUpdate?()
    }

    private func releaseAssertions() {
        assertions.forEach { IOPMAssertionRelease($0) }
        assertions.removeAll()
    }

    private func finish(reason: String) {
        releaseAssertions()
        if let leaseURL { try? FileManager.default.removeItem(at: leaseURL) }
        leaseURL = nil; sessionID = nil; activeOptions = nil
        phase = .idle; remaining = nil; stoppingSince = nil
        message = reason.isEmpty ? "Session ended" : reason
        refreshRecovery()
        onUpdate?()
        onStopped?()
    }

    private func tick() {
        power = .current()
        if phase == .starting || phase == .running {
            if activeOptions?.mode == .closedLid {
                do { try writeLease(active: true) }
                catch { errorMessage = "The session heartbeat could not be saved. Closed-lid mode will stop automatically." }
            }
        }
        if phase == .running, let options = activeOptions {
            let elapsed = ProcessInfo.processInfo.systemUptime - startedUptime
            remaining = options.minutes == 0 ? nil : max(0, Double(options.minutes * 60) - elapsed)
            if options.mode == .ordinary, let reason = SessionPolicy.stopReason(options: options, power: power, elapsed: elapsed) { finish(reason: reason) }
        }
        if (phase == .running || phase == .stopping), activeOptions?.mode == .closedLid,
           let state = HelperStatus.read(), state.sessionID == sessionID {
            if state.hasFinished {
                finish(reason: state.needsRestore ? "Interrupted session. Restore normal sleep." : state.reason)
            }
        }
        if phase == .stopping, let since = stoppingSince, Date().timeIntervalSince(since) > 15 {
            errorMessage = "The helper has not confirmed that sleep was restored. You can quit to end its heartbeat, then reopen Keep Awake to check recovery."
        }
        if phase == .idle { refreshRecovery() }
        onUpdate?()
    }

    func refreshRecovery() {
        let state = HelperStatus.read()
        needsRecovery = state?.owner == getuid() && state?.needsRecovery == true
    }

    func recover() {
        guard phase == .idle, needsRecovery else { return }
        phase = .stopping
        authorize(arguments: ["--recover", String(getuid())]) { [weak self] error in
            guard let self else { return }
            self.phase = .idle
            self.errorMessage = error
            self.message = error == nil ? "Normal sleep restored" : "Recovery did not finish"
            self.refreshRecovery(); self.onUpdate?()
        }
    }

    func refreshLogin() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    func setLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { errorMessage = error.localizedDescription }
        refreshLogin()
    }

    func prepareToQuit() {
        timer?.invalidate()
        try? writeLease(active: false)
        releaseAssertions()
    }
}
