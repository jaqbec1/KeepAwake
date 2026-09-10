import Foundation

enum Phase: Equatable {
    case idle, starting, running, stopping
}

enum SleepAssertionKind: Equatable {
    case system
    case display
}

enum AuthorizationResult: Equatable {
    case succeeded
    case cancelled
    case failedBeforeLaunch(String)
    case failed(String)

    var errorMessage: String? {
        switch self {
        case .succeeded: return nil
        case .cancelled: return "Administrator approval was cancelled."
        case .failedBeforeLaunch(let message), .failed(let message): return message
        }
    }
}

typealias AuthorizationCompletion = @MainActor @Sendable (AuthorizationResult) -> Void

@MainActor
struct SessionDependencies {
    var wallNow: () -> Date
    var uptime: () -> TimeInterval
    var powerSnapshot: () -> PowerSnapshot
    var currentProcess: () -> ProcessIdentity?
    var owner: () -> uid_t
    var makeSessionID: () -> String
    var leaseDirectory: URL
    var readHelperStatus: () -> HelperStatus?
    var helperHasFinished: (HelperStatus) -> Bool
    var helperNeedsRecovery: (HelperStatus) -> Bool
    var authorize: (_ arguments: [String], _ completion: @escaping AuthorizationCompletion) -> Void
    var takeAssertion: (SleepAssertionKind) throws -> UInt32
    var releaseAssertion: (UInt32) -> Void
    var beginActivity: () -> Void
    var endActivity: () -> Void
}

private struct SessionContext {
    var options: SessionOptions
    var startedUptime: TimeInterval
    var sessionID: String?
    var leaseURL: URL?
    var requestedStopReason: String?
}

private enum SessionLifecycle {
    case idle
    case starting(SessionContext)
    case running(SessionContext)
    case stopping(SessionContext, sinceUptime: TimeInterval)
    case recovering(sinceUptime: TimeInterval)
}

@MainActor
final class SessionController {
    private let dependencies: SessionDependencies
    private var lifecycle: SessionLifecycle = .idle
    private var assertions: [UInt32] = []
    private var activityActive = false

    private(set) var power: PowerSnapshot
    private(set) var remaining: TimeInterval?
    private(set) var message = "Ready when you are"
    private(set) var errorMessage: String?
    private(set) var needsRecovery = false
    var onUpdate: (() -> Void)?
    var onStopped: (() -> Void)?

    init(dependencies: SessionDependencies) {
        self.dependencies = dependencies
        power = dependencies.powerSnapshot()
        refreshRecovery(notify: false)
    }

    var phase: Phase {
        switch lifecycle {
        case .idle: return .idle
        case .starting: return .starting
        case .running: return .running
        case .stopping, .recovering: return .stopping
        }
    }

    var isBusy: Bool { phase != .idle }
    var isRunning: Bool { phase == .running }

    var statusTitle: String {
        switch lifecycle {
        case .idle: return needsRecovery ? "Sleep needs restoring" : "Ready"
        case .starting: return "Starting session…"
        case .running(let context):
            return context.options.mode == .closedLid ? "Awake with lid closed" : "Keeping your Mac awake"
        case .stopping, .recovering: return "Restoring normal sleep…"
        }
    }

    var countdown: String {
        guard let remaining else { return "Until stopped" }
        let seconds = max(0, Int(remaining.rounded(.up)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func start(options: SessionOptions) {
        guard case .idle = lifecycle else { return }
        errorMessage = nil
        do {
            try options.validate()
            power = dependencies.powerSnapshot()
            if let reason = SessionPolicy.stopReason(options: options, power: power, elapsed: 0) {
                throw AwakeError(reason)
            }
            if options.mode == .closedLid && needsRecovery {
                throw AwakeError("Restore normal sleep before starting another closed-lid session.")
            }
            beginActivity()
            if options.mode == .closedLid {
                try startClosedLid(options)
            } else {
                try startOrdinary(options)
            }
        } catch {
            failStart(error.localizedDescription)
        }
        notify()
    }

    private func startOrdinary(_ options: SessionOptions) throws {
        assertions.append(try dependencies.takeAssertion(.system))
        if options.keepDisplayOn {
            assertions.append(try dependencies.takeAssertion(.display))
        }
        lifecycle = .running(SessionContext(options: options, startedUptime: dependencies.uptime(), sessionID: nil, leaseURL: nil, requestedStopReason: nil))
        remaining = options.minutes == 0 ? nil : Double(options.minutes * 60)
        message = runningMessage(options)
    }

    private func startClosedLid(_ options: SessionOptions) throws {
        guard let parent = dependencies.currentProcess() else {
            throw AwakeError("The app could not identify this session.")
        }
        let sessionID = dependencies.makeSessionID()
        guard UUID(uuidString: sessionID) != nil else {
            throw AwakeError("The app could not create this session.")
        }
        try FileManager.default.createDirectory(
            at: dependencies.leaseDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let leaseURL = dependencies.leaseDirectory.appendingPathComponent(sessionID + ".json")
        let context = SessionContext(options: options, startedUptime: dependencies.uptime(), sessionID: sessionID, leaseURL: leaseURL, requestedStopReason: nil)
        try writeLease(context: context, active: true)
        let request = HelperRequest(sessionID: sessionID, parent: parent, leasePath: leaseURL.path, options: options)
        let payload = try JSONEncoder().encode(request).base64EncodedString()
        lifecycle = .starting(context)
        remaining = options.minutes == 0 ? nil : Double(options.minutes * 60)
        message = "Approve the macOS administrator prompt to begin"
        dependencies.authorize(["--launch", payload]) { [weak self] result in
            self?.authorizationFinished(sessionID: sessionID, result: result)
        }
    }

    private func authorizationFinished(sessionID: String, result: AuthorizationResult) {
        guard case .starting(var context) = lifecycle, context.sessionID == sessionID else { return }
        let status = matchingStatus(for: context)
        if let error = result.errorMessage {
            try? writeLease(context: context, active: false)
            if result == .cancelled {
                finish(reason: error, error: error)
            } else if case .failedBeforeLaunch = result {
                finish(reason: error, error: error)
            } else if let status {
                if dependencies.helperHasFinished(status) {
                    if status.needsRestore || dependencies.helperNeedsRecovery(status) {
                        finishFromHelper(status, context: context)
                    } else {
                        finish(reason: error, error: error)
                    }
                    errorMessage = error
                } else {
                    beginStopping(context, error: error)
                }
            } else {
                beginStopping(context, error: error)
            }
            refreshRecovery(notify: false)
            notify()
            return
        }

        guard let status else {
            try? writeLease(context: context, active: false)
            lifecycle = .stopping(context, sinceUptime: dependencies.uptime())
            message = "Waiting for the helper to confirm normal sleep"
            errorMessage = "The helper did not provide a readable session status. Keep Awake will not assume that normal sleep was restored."
            notify()
            return
        }
        if status.state == "running" && !dependencies.helperHasFinished(status) {
            context.startedUptime = dependencies.uptime()
            lifecycle = .running(context)
            remaining = context.options.minutes == 0 ? nil : Double(context.options.minutes * 60)
            message = runningMessage(context.options)
        } else if dependencies.helperHasFinished(status) {
            finishFromHelper(status, context: context)
        } else {
            try? writeLease(context: context, active: false)
            beginStopping(
                context,
                error: status.reason.isEmpty ? "The helper did not confirm that the session started." : status.reason
            )
        }
        refreshRecovery(notify: false)
        notify()
    }

    func stop(reason: String = "Stopped") {
        guard case .running(var context) = lifecycle else { return }
        if context.options.mode == .closedLid {
            context.requestedStopReason = reason
            do {
                try writeLease(context: context, active: false)
            } catch {
                errorMessage = "The stop request could not be saved. The helper will stop when the app exits or its heartbeat expires."
            }
            lifecycle = .stopping(context, sinceUptime: dependencies.uptime())
            message = "Waiting for the helper to restore normal sleep"
        } else {
            finish(reason: reason)
        }
        notify()
    }

    func tick() {
        power = dependencies.powerSnapshot()
        let now = dependencies.uptime()

        switch lifecycle {
        case .starting(let context):
            do { try writeLease(context: context, active: true) }
            catch { errorMessage = "The session heartbeat could not be saved. Closed-lid mode will stop automatically." }
        case .running(let context):
            if context.options.mode == .closedLid {
                do { try writeLease(context: context, active: true) }
                catch { errorMessage = "The session heartbeat could not be saved. Closed-lid mode will stop automatically." }
            }
            let elapsed = max(0, now - context.startedUptime)
            remaining = context.options.minutes == 0 ? nil : max(0, Double(context.options.minutes * 60) - elapsed)
            if let reason = SessionPolicy.stopReason(options: context.options, power: power, elapsed: elapsed) {
                stop(reason: reason)
            }
            if phase == .running && context.options.mode == .closedLid {
                if matchingStatus(for: context) == nil {
                    try? writeLease(context: context, active: false)
                    beginStopping(
                        context,
                        error: "The helper status could not be read. Keep Awake requested a safe stop and is waiting for normal sleep to be restored."
                    )
                } else {
                    handleHelperStatus(for: context)
                }
            }
        case .stopping(let context, let sinceUptime):
            handleHelperStatus(for: context)
            if phase == .stopping && now - sinceUptime > 15 {
                errorMessage = "The helper has not confirmed that sleep was restored. You can quit to end its heartbeat, then reopen Keep Awake to check recovery."
            }
        case .recovering(let sinceUptime):
            if now - sinceUptime > 15 {
                errorMessage = "Recovery has not finished. Complete or cancel the administrator prompt, then try again."
            }
        case .idle:
            refreshRecovery(notify: false)
        }
        notify()
    }

    private func handleHelperStatus(for context: SessionContext) {
        guard let status = matchingStatus(for: context), dependencies.helperHasFinished(status) else { return }
        finishFromHelper(status, context: context)
    }

    private func beginStopping(_ context: SessionContext, error: String?) {
        lifecycle = .stopping(context, sinceUptime: dependencies.uptime())
        message = "Waiting for the helper to restore normal sleep"
        errorMessage = error
    }

    private func finishFromHelper(_ status: HelperStatus, context: SessionContext) {
        if status.needsRestore || dependencies.helperNeedsRecovery(status) {
            finish(reason: "Interrupted session. Restore normal sleep.")
        } else {
            finish(reason: context.requestedStopReason ?? (status.reason.isEmpty ? "Session ended" : status.reason))
        }
    }

    func recover() {
        guard case .idle = lifecycle, needsRecovery else { return }
        errorMessage = nil
        beginActivity()
        lifecycle = .recovering(sinceUptime: dependencies.uptime())
        message = "Approve the macOS administrator prompt to restore normal sleep"
        dependencies.authorize(["--recover", String(dependencies.owner())]) { [weak self] result in
            guard let self else { return }
            self.refreshRecovery(notify: false)
            self.lifecycle = .idle
            self.endActivity()
            if let error = result.errorMessage {
                self.errorMessage = error
                self.message = error
            } else if self.needsRecovery {
                self.errorMessage = "The helper did not confirm that normal sleep was restored."
                self.message = "Recovery did not finish"
            } else {
                self.message = "Normal sleep restored"
            }
            self.notify()
            self.onStopped?()
        }
        notify()
    }

    func refreshRecovery() {
        refreshRecovery(notify: true)
    }

    private func refreshRecovery(notify shouldNotify: Bool) {
        let status = dependencies.readHelperStatus()
        needsRecovery = status?.owner == dependencies.owner() && status.map(dependencies.helperNeedsRecovery) == true
        if shouldNotify { notify() }
    }

    func clearError() {
        guard phase == .idle, errorMessage != nil else { return }
        errorMessage = nil
        notify()
    }

    func report(error: String) {
        errorMessage = error
        if phase == .idle { message = error }
        notify()
    }

    func prepareToQuit() {
        switch lifecycle {
        case .starting(let context), .running(let context), .stopping(let context, _):
            if context.options.mode == .closedLid { try? writeLease(context: context, active: false) }
        case .idle, .recovering:
            break
        }
        releaseAssertions()
        endActivity()
    }

    private func failStart(_ reason: String) {
        releaseAssertions()
        if let context = currentContext, let leaseURL = context.leaseURL {
            try? FileManager.default.removeItem(at: leaseURL)
        }
        lifecycle = .idle
        remaining = nil
        errorMessage = reason
        message = reason
        endActivity()
        refreshRecovery(notify: false)
    }

    private func finish(reason: String, error: String? = nil) {
        let context = currentContext
        releaseAssertions()
        if let leaseURL = context?.leaseURL { try? FileManager.default.removeItem(at: leaseURL) }
        lifecycle = .idle
        remaining = nil
        errorMessage = error
        message = reason.isEmpty ? "Session ended" : reason
        endActivity()
        refreshRecovery(notify: false)
        notify()
        onStopped?()
    }

    private var currentContext: SessionContext? {
        switch lifecycle {
        case .starting(let context), .running(let context), .stopping(let context, _): return context
        case .idle, .recovering: return nil
        }
    }

    private func matchingStatus(for context: SessionContext) -> HelperStatus? {
        guard let sessionID = context.sessionID,
              let status = dependencies.readHelperStatus(),
              status.sessionID == sessionID,
              status.owner == dependencies.owner() else { return nil }
        return status
    }

    private func writeLease(context: SessionContext, active: Bool) throws {
        guard let sessionID = context.sessionID, let leaseURL = context.leaseURL else { return }
        let lease = Lease(
            sessionID: sessionID,
            active: active,
            updated: dependencies.wallNow(),
            updatedUptime: dependencies.uptime()
        )
        try JSONEncoder().encode(lease).write(to: leaseURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: leaseURL.path)
    }

    private func runningMessage(_ options: SessionOptions) -> String {
        options.chargerOnly ? "Ends when you unplug the charger" : "Stops at \(options.batteryFloor)% battery"
    }

    private func beginActivity() {
        guard !activityActive else { return }
        dependencies.beginActivity()
        activityActive = true
    }

    private func endActivity() {
        guard activityActive else { return }
        dependencies.endActivity()
        activityActive = false
    }

    private func releaseAssertions() {
        assertions.forEach(dependencies.releaseAssertion)
        assertions.removeAll()
    }

    private func notify() {
        onUpdate?()
    }
}
