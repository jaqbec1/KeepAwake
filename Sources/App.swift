import AppKit
import ServiceManagement
import IOKit.pwr_mgt

@MainActor
private final class ProcessActivityScope {
    private var token: NSObjectProtocol?

    func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Keep Awake session"
        )
    }

    func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}

private enum AuthorizationRunner {
    @MainActor
    static func run(arguments: [String], completion: @escaping AuthorizationCompletion) {
        guard let helper = Bundle.main.url(forResource: "KeepAwakeHelper", withExtension: nil) else {
            completion(.failedBeforeLaunch("The app is missing its session helper. Install a fresh copy."))
            return
        }
        func shellQuote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let command = ([helper.path] + arguments).map(shellQuote).joined(separator: " ")
        let literal = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(literal)\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            var details: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&details)
            let result: AuthorizationResult
            if let details {
                let number = details[NSAppleScript.errorNumber] as? Int
                result = number == -128
                    ? .cancelled
                    : .failed(details[NSAppleScript.errorMessage] as? String ?? "Administrator approval failed.")
            } else {
                result = .succeeded
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

@MainActor
extension SessionDependencies {
    static func live() -> SessionDependencies {
        let activity = ProcessActivityScope()
        return SessionDependencies(
            wallNow: Date.init,
            uptime: { ProcessInfo.processInfo.systemUptime },
            powerSnapshot: PowerSnapshot.current,
            currentProcess: { ProcessIdentity.read(getpid()) },
            owner: { getuid() },
            makeSessionID: { UUID().uuidString },
            leaseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(AppInfo.identifier, isDirectory: true),
            readHelperStatus: HelperStatus.read,
            helperHasFinished: { $0.hasFinished },
            helperNeedsRecovery: { $0.needsRecovery },
            authorize: AuthorizationRunner.run,
            takeAssertion: { kind in
                let type = kind == .system
                    ? kIOPMAssertionTypePreventUserIdleSystemSleep
                    : kIOPMAssertionTypePreventUserIdleDisplaySleep
                var id: IOPMAssertionID = 0
                let code = IOPMAssertionCreateWithName(
                    type as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "Keep Awake session" as CFString,
                    &id
                )
                guard code == kIOReturnSuccess else {
                    throw AwakeError("macOS could not start sleep prevention. Error \(code).")
                }
                return id
            },
            releaseAssertion: { IOPMAssertionRelease($0) },
            beginActivity: activity.begin,
            endActivity: activity.end
        )
    }
}

@MainActor
final class AwakeModel {
    var mode: SessionMode = .ordinary { didSet { persist() } }
    var duration = 60 { didSet { persist() } }
    var customMinutes = "60" { didSet { persist() } }
    var chargerOnly = true { didSet { persist() } }
    var batteryFloor = 20 { didSet { persist() } }
    var keepDisplayOn = false { didSet { persist() } }
    var showCountdown = true { didSet { persist() } }
    var phase: Phase { controller.phase }
    var power: PowerSnapshot { controller.power }
    var remaining: TimeInterval? { controller.remaining }
    var message: String { controller.message }
    var errorMessage: String? { controller.errorMessage }
    var needsRecovery: Bool { controller.needsRecovery }
    private(set) var loginEnabled = false
    private(set) var loginNeedsApproval = false
    var onUpdate: (() -> Void)?
    var onStopped: (() -> Void)?

    private let defaults: UserDefaults
    private let controller: SessionController
    private var timer: Timer?
    private var loaded = false

    init(defaults: UserDefaults = .standard, dependencies: SessionDependencies? = nil, installTimer: Bool = true, refreshLoginAtLaunch: Bool = true) {
        self.defaults = defaults
        controller = SessionController(dependencies: dependencies ?? .live())
        mode = SessionMode(rawValue: defaults.string(forKey: "mode") ?? "ordinary") ?? .ordinary
        duration = defaults.object(forKey: "duration") as? Int ?? 60
        customMinutes = defaults.string(forKey: "customMinutes") ?? "60"
        chargerOnly = defaults.object(forKey: "chargerOnly") as? Bool ?? true
        batteryFloor = defaults.object(forKey: "batteryFloor") as? Int ?? 20
        keepDisplayOn = defaults.bool(forKey: "keepDisplayOn")
        showCountdown = defaults.object(forKey: "showCountdown") as? Bool ?? true
        loaded = true
        controller.onUpdate = { [weak self] in self?.onUpdate?() }
        controller.onStopped = { [weak self] in self?.onStopped?() }
        if refreshLoginAtLaunch { refreshLogin() }
        if installTimer {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func persist() {
        guard loaded else { return }
        if phase == .idle { controller.clearError() }
        defaults.set(mode.rawValue, forKey: "mode")
        defaults.set(duration, forKey: "duration")
        defaults.set(customMinutes, forKey: "customMinutes")
        defaults.set(chargerOnly, forKey: "chargerOnly")
        defaults.set(batteryFloor, forKey: "batteryFloor")
        defaults.set(keepDisplayOn, forKey: "keepDisplayOn")
        defaults.set(showCountdown, forKey: "showCountdown")
        onUpdate?()
    }

    var isBusy: Bool { controller.isBusy }
    var isRunning: Bool { controller.isRunning }
    var statusTitle: String { controller.statusTitle }
    var countdown: String { controller.countdown }

    func options() throws -> SessionOptions {
        guard let minutes = duration == -1
            ? Int(customMinutes.trimmingCharacters(in: .whitespacesAndNewlines))
            : duration else {
            throw AwakeError("Enter a whole number of minutes.")
        }
        if duration == -1 && minutes == 0 {
            throw AwakeError("Enter at least one minute, or choose Until stopped.")
        }
        let result = SessionOptions(
            mode: mode,
            minutes: minutes,
            chargerOnly: chargerOnly,
            batteryFloor: batteryFloor,
            keepDisplayOn: mode == .ordinary && keepDisplayOn
        )
        try result.validate()
        return result
    }

    func start() {
        do {
            controller.start(options: try options())
        } catch {
            controller.report(error: error.localizedDescription)
        }
    }

    func stop(reason: String = "Stopped") {
        controller.stop(reason: reason)
    }

    func recover() {
        controller.recover()
    }

    func refreshRecovery() {
        controller.refreshRecovery()
    }

    func refreshLogin() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    func setLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            controller.report(error: error.localizedDescription)
        }
        refreshLogin()
    }

    func prepareToQuit() {
        timer?.invalidate()
        timer = nil
        controller.prepareToQuit()
    }

}
