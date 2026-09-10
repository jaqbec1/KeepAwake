import Foundation
import IOKit.pwr_mgt

@main
struct SessionControllerTests {
    @MainActor
    static func main() throws {
        try closedLidSessionContinuesWhenHelperDetailsArePermissionDenied()
        try closedLidStopWaitsForConfirmedRestoration()
        try ordinaryDisplayAssertionFailureReleasesSystemAssertion()
        try authorizationCancellationCleansUpAndAllowsRetry()
        try timerAndPowerPolicyStopActiveSessions()
        try delayedAuthorizationStartsWithFullDuration()
        try pendingAuthorizationBlocksAnotherStart()
        try unknownAuthorizationFailureWaitsForRestorationEvidence()
        try closedLidPolicyStopKeepsItsReasonThroughRestoration()
        try missingHelperStatusRequestsSafeStop()
        try stoppingTimeoutUsesMonotonicTime()
        try terminalHelperStateOffersAndCompletesRecovery()
        try recoveryFailuresStayVisible()
        try incompleteRecoveryRemainsActionable()
        try helperExitEndsSessionAndOffersRecovery()
        try awakeModelUsesInjectedControllerWithoutLiveSideEffects()
        print("16 session controller checks passed. No authorization or power-setting request was made.")
    }

    @MainActor
    private static func closedLidStopWaitsForConfirmedRestoration() throws {
        let fixture = try Fixture()
        fixture.status = fixture.runningStatus()
        let controller = SessionController(dependencies: fixture.dependencies)
        controller.start(options: fixture.closedLidOptions)

        controller.stop()
        try require(controller.phase == .stopping, "A closed-lid stop returned to idle before restoration")
        let stoppedLease = try fixture.readLease()
        try require(!stoppedLease.active, "The stop request did not mark the lease inactive")

        controller.tick()
        try require(controller.phase == .stopping, "A running helper was mistaken for restored sleep")
        try require(fixture.leaseExists, "The lease was removed before the helper confirmed restoration")

        fixture.status = fixture.status(state: "stopped", needsRestore: false, reason: "Stopped")
        controller.tick()
        try require(controller.phase == .idle, "Confirmed restoration did not finish the session")
        try require(!fixture.leaseExists, "The lease remained after confirmed restoration")
    }

    @MainActor
    private static func ordinaryDisplayAssertionFailureReleasesSystemAssertion() throws {
        let fixture = try Fixture()
        fixture.assertionFailure = .display
        let controller = SessionController(dependencies: fixture.dependencies)
        let options = SessionOptions(mode: .ordinary, minutes: 60, chargerOnly: true, batteryFloor: 20, keepDisplayOn: true)

        controller.start(options: options)

        try require(controller.phase == .idle, "A partial assertion failure left the session active")
        try require(fixture.assertionRequests == [.system, .display], "The display assertion failure was not exercised")
        try require(fixture.releasedAssertions == [1], "The system assertion was not released after display assertion failure")
        try require(controller.errorMessage == "Display assertion rejected", "The assertion failure was not shown to the user")
        try require(fixture.activityBegins == 1 && fixture.activityEnds == 1, "The process activity outlived the failed start")
    }

    @MainActor
    private static func authorizationCancellationCleansUpAndAllowsRetry() throws {
        let fixture = try Fixture()
        fixture.authorizationResult = .cancelled
        let controller = SessionController(dependencies: fixture.dependencies)

        controller.start(options: fixture.closedLidOptions)

        try require(controller.phase == .idle, "Cancelling authorization left a session active")
        try require(controller.message == "Administrator approval was cancelled.", "Cancellation disappeared from the session outcome")
        try require(controller.errorMessage == "Administrator approval was cancelled.", "Cancellation was not available to the UI")
        try require(!fixture.leaseExists, "Cancelling authorization left a lease behind")
        try require(!controller.needsRecovery, "Cancellation claimed recovery without a helper change")

        fixture.status = fixture.runningStatus()
        fixture.authorizationResult = .succeeded
        controller.start(options: fixture.closedLidOptions)

        try require(controller.phase == .running, "A new session could not start after authorization cancellation")
        try require(fixture.authorizationRequests.count == 2, "The retry did not request authorization")
    }

    @MainActor
    private static func timerAndPowerPolicyStopActiveSessions() throws {
        let timerFixture = try Fixture()
        let timerController = SessionController(dependencies: timerFixture.dependencies)
        timerController.start(options: SessionOptions(mode: .ordinary, minutes: 1, chargerOnly: true, batteryFloor: 20, keepDisplayOn: false))
        timerFixture.advance(seconds: 60)
        timerController.tick()
        try require(timerController.phase == .idle, "The exact timer deadline did not stop the session")
        try require(timerController.message == "Timer finished", "The timer stop reason was lost")
        try require(timerFixture.releasedAssertions == [1], "Timer stop did not release the sleep assertion")

        let powerFixture = try Fixture()
        let powerController = SessionController(dependencies: powerFixture.dependencies)
        powerController.start(options: SessionOptions(mode: .ordinary, minutes: 0, chargerOnly: true, batteryFloor: 20, keepDisplayOn: false))
        powerFixture.powerSnapshot.onAC = false
        powerFixture.advance(seconds: 1)
        powerController.tick()
        try require(powerController.phase == .idle, "Unplugging the charger did not stop the session")
        try require(powerController.message == "Connect the power adapter to continue", "The power stop reason was lost")
        try require(powerFixture.releasedAssertions == [1], "Power stop did not release the sleep assertion")
    }

    @MainActor
    private static func delayedAuthorizationStartsWithFullDuration() throws {
        let fixture = try Fixture()
        fixture.status = fixture.runningStatus()
        fixture.holdAuthorization = true
        let controller = SessionController(dependencies: fixture.dependencies)
        var options = fixture.closedLidOptions
        options.minutes = 1

        controller.start(options: options)
        fixture.advance(seconds: 61)
        controller.tick()
        try require(controller.phase == .starting, "A pending administrator prompt did not keep the session starting")

        fixture.completeAuthorization()

        try require(controller.phase == .running, "Delayed approval did not start the session")
        try require(controller.remaining == 60, "Time spent waiting for approval reduced the session duration")
    }

    @MainActor
    private static func pendingAuthorizationBlocksAnotherStart() throws {
        let fixture = try Fixture()
        fixture.holdAuthorization = true
        let controller = SessionController(dependencies: fixture.dependencies)

        controller.start(options: fixture.closedLidOptions)
        fixture.status = fixture.status(state: "stopped", needsRestore: false, reason: "Session ended")
        controller.tick()
        controller.start(options: fixture.closedLidOptions)

        try require(controller.phase == .starting, "A terminal journal ended the session before authorization returned")
        try require(fixture.authorizationRequests.count == 1, "A second start launched while authorization was pending")
        try require(fixture.activityEnds == 0, "Session activity ended while authorization was pending")

        fixture.completeAuthorization()
        try require(controller.phase == .idle, "The held authorization result did not finish the terminal session")
        try require(fixture.activityEnds == 1, "Session activity remained after authorization completed")
    }

    @MainActor
    private static func unknownAuthorizationFailureWaitsForRestorationEvidence() throws {
        let fixture = try Fixture()
        fixture.authorizationResult = .failed("Authorization transport failed")
        let controller = SessionController(dependencies: fixture.dependencies)

        controller.start(options: fixture.closedLidOptions)

        try require(controller.phase == .stopping, "An uncertain helper launch was reported as idle without restoration evidence")
        let inactiveLease = try fixture.readLease()
        try require(!inactiveLease.active, "An uncertain helper launch kept an active heartbeat")
        try require(fixture.activityEnds == 0, "The session activity ended before restoration was confirmed")

        fixture.status = fixture.status(state: "stopped", needsRestore: false, reason: "Normal sleep restored")
        controller.tick()
        try require(controller.phase == .idle, "Confirmed restoration did not resolve the uncertain launch")
        try require(!fixture.leaseExists, "The uncertain launch lease remained after restoration")
        try require(fixture.activityEnds == 1, "The session activity remained after restoration")

        let startingFixture = try Fixture()
        startingFixture.status = startingFixture.status(state: "starting", needsRestore: false, reason: "")
        startingFixture.authorizationResult = .failed("Authorization transport failed")
        let startingController = SessionController(dependencies: startingFixture.dependencies)
        startingController.start(options: startingFixture.closedLidOptions)
        try require(startingController.phase == .stopping, "A live starting helper was reported as idle after an uncertain launch")
        let startingLease = try startingFixture.readLease()
        try require(!startingLease.active, "A live starting helper retained an active lease after launch uncertainty")
    }

    @MainActor
    private static func closedLidPolicyStopKeepsItsReasonThroughRestoration() throws {
        let fixture = try Fixture()
        fixture.status = fixture.runningStatus()
        let controller = SessionController(dependencies: fixture.dependencies)
        var options = fixture.closedLidOptions
        options.minutes = 1
        controller.start(options: options)

        fixture.advance(seconds: 60)
        controller.tick()
        try require(controller.phase == .stopping, "The closed-lid timer did not request a safe stop")

        fixture.status = fixture.status(state: "stopped", needsRestore: false, reason: "Stopped")
        controller.tick()
        try require(controller.phase == .idle, "The closed-lid timer did not finish after restoration")
        try require(controller.message == "Timer finished", "Restoration replaced the automatic stop reason")
    }

    @MainActor
    private static func missingHelperStatusRequestsSafeStop() throws {
        let fixture = try Fixture()
        fixture.status = fixture.runningStatus()
        let controller = SessionController(dependencies: fixture.dependencies)
        controller.start(options: fixture.closedLidOptions)

        fixture.status = nil
        controller.tick()

        try require(controller.phase == .stopping, "Missing helper status was reported as a completed session")
        try require(controller.errorMessage?.contains("status could not be read") == true, "Missing helper status had no actionable outcome")
        let lease = try fixture.readLease()
        try require(!lease.active, "Missing helper status left the helper heartbeat active")
    }

    @MainActor
    private static func stoppingTimeoutUsesMonotonicTime() throws {
        let fixture = try Fixture()
        fixture.status = fixture.runningStatus()
        let controller = SessionController(dependencies: fixture.dependencies)
        controller.start(options: fixture.closedLidOptions)
        controller.stop()

        fixture.wallNow = fixture.wallNow.addingTimeInterval(3_600)
        controller.tick()
        try require(controller.errorMessage == nil, "A wall-clock jump triggered the restoration timeout")

        fixture.uptime += 16
        controller.tick()
        try require(controller.errorMessage?.contains("has not confirmed") == true, "Monotonic timeout did not report missing restoration")
    }

    @MainActor
    private static func terminalHelperStateOffersAndCompletesRecovery() throws {
        let fixture = try Fixture()
        fixture.status = fixture.status(state: "recoveryRequired", needsRestore: true, reason: "Restore failed")
        let controller = SessionController(dependencies: fixture.dependencies)
        try require(controller.needsRecovery, "A terminal helper restore failure did not offer recovery")

        fixture.onAuthorize = { arguments in
            if arguments.first == "--recover" {
                fixture.status = fixture.status(state: "stopped", needsRestore: false, reason: "Normal sleep restored")
            }
        }
        controller.recover()

        try require(controller.phase == .idle, "Successful recovery did not return to idle")
        try require(!controller.needsRecovery, "Successful recovery left recovery enabled")
        try require(controller.message == "Normal sleep restored", "Successful recovery did not report its outcome")
        try require(fixture.authorizationRequests.first?.first == "--recover", "Recovery used the wrong helper command")
        try require(fixture.activityBegins == 1 && fixture.activityEnds == 1, "Recovery did not scope its process activity")
    }

    @MainActor
    private static func recoveryFailuresStayVisible() throws {
        for result in [AuthorizationResult.cancelled, .failed("Recovery transport failed")] {
            let fixture = try Fixture()
            fixture.status = fixture.status(state: "recoveryRequired", needsRestore: true, reason: "Restore failed")
            fixture.authorizationResult = result
            let controller = SessionController(dependencies: fixture.dependencies)

            controller.recover()

            try require(controller.phase == .idle, "A failed recovery did not return control to the menu")
            try require(controller.message == result.errorMessage, "A failed recovery hid its outcome")
            try require(controller.errorMessage == result.errorMessage, "A failed recovery did not remain visible as an error")
            try require(controller.needsRecovery, "A failed recovery removed the recovery action")
            try require(fixture.activityBegins == 1 && fixture.activityEnds == 1, "A failed recovery leaked process activity")
        }
    }

    @MainActor
    private static func incompleteRecoveryRemainsActionable() throws {
        let fixture = try Fixture()
        fixture.status = fixture.status(state: "recoveryRequired", needsRestore: true, reason: "Restore failed")
        let controller = SessionController(dependencies: fixture.dependencies)

        controller.recover()

        try require(controller.phase == .idle, "An incomplete recovery did not return control to the menu")
        try require(controller.message == "Recovery did not finish", "An incomplete recovery reported success")
        try require(controller.errorMessage == "The helper did not confirm that normal sleep was restored.", "An incomplete recovery hid its explanation")
        try require(controller.needsRecovery, "An incomplete recovery removed the recovery action")
        try require(fixture.activityBegins == 1 && fixture.activityEnds == 1, "An incomplete recovery leaked process activity")
    }

    @MainActor
    private static func helperExitEndsSessionAndOffersRecovery() throws {
        let fixture = try Fixture()
        fixture.status = fixture.runningStatus()
        let controller = SessionController(dependencies: fixture.dependencies)
        controller.start(options: fixture.closedLidOptions)

        fixture.helperFinished = true
        fixture.helperRecovery = true
        controller.tick()

        try require(controller.phase == .idle, "An exited helper left the app session running")
        try require(controller.needsRecovery, "An exited helper with unrestored sleep did not offer recovery")
        try require(controller.message == "Interrupted session. Restore normal sleep.", "The helper exit outcome was misleading")
        try require(!fixture.leaseExists, "The helper exit left its lease behind")
    }

    @MainActor
    private static func awakeModelUsesInjectedControllerWithoutLiveSideEffects() throws {
        let fixture = try Fixture()
        let defaults = UserDefaults(suiteName: "keepawake-model-" + UUID().uuidString)!
        let model = AwakeModel(defaults: defaults, dependencies: fixture.dependencies, installTimer: false, refreshLoginAtLaunch: false)

        try require(model.phase == .idle && model.power.batteryPercent == 90, "The facade did not mirror its injected controller")
        try require(fixture.authorizationRequests.isEmpty && fixture.assertionRequests.isEmpty, "Constructing the facade triggered a session side effect")
        model.start()
        try require(model.phase == .running && model.statusTitle == "Keeping your Mac awake", "The facade did not start through the controller")
        model.prepareToQuit()
        try require(fixture.releasedAssertions == [1], "The facade did not release the controller assertion on quit")
    }

    @MainActor
    private static func closedLidSessionContinuesWhenHelperDetailsArePermissionDenied() throws {
        let fixture = try Fixture()
        fixture.status = fixture.runningStatus()
        fixture.authorizationResult = .succeeded

        try require(ProcessIdentity.read(1) == nil, "This regression check must run as an ordinary app user without root process details")

        let controller = SessionController(dependencies: fixture.dependencies)
        controller.start(options: fixture.closedLidOptions)
        try require(controller.phase == .running, "The closed-lid session did not reach running")

        let firstHeartbeat = try fixture.readLease().updated

        fixture.advance(seconds: 1)
        controller.tick()

        try require(controller.phase == .running, "Permission-denied process details ended a running helper session")
        let lease = try fixture.readLease()
        try require(lease.active, "The app did not keep the helper heartbeat active")
        try require(lease.updated > firstHeartbeat, "The helper heartbeat timestamp did not advance")
        try require(fixture.authorizationRequests.count == 1, "The test unexpectedly retried authorization")
        try require(fixture.assertionRequests.isEmpty, "Closed-lid mode unexpectedly used local power assertions")
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let sessionID = "00000000-0000-4000-8000-000000000001"
    var wallNow = Date(timeIntervalSince1970: 1_700_000_000)
    var uptime: TimeInterval = 10_000
    var powerSnapshot = PowerSnapshot(onAC: true, batteryPercent: 90, lidClosed: false, thermal: .nominal)
    var status: HelperStatus?
    var helperFinished: Bool?
    var helperRecovery: Bool?
    var authorizationResult: AuthorizationResult = .succeeded
    var authorizationRequests: [[String]] = []
    var holdAuthorization = false
    var heldAuthorizationCompletion: AuthorizationCompletion?
    var onAuthorize: (([String]) -> Void)?
    var assertionRequests: [SleepAssertionKind] = []
    var assertionFailure: SleepAssertionKind?
    var releasedAssertions: [UInt32] = []
    var activityBegins = 0
    var activityEnds = 0

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("keepawake-controller-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var closedLidOptions: SessionOptions {
        SessionOptions(mode: .closedLid, minutes: 60, chargerOnly: true, batteryFloor: 20, keepDisplayOn: false)
    }

    var dependencies: SessionDependencies {
        SessionDependencies(
            wallNow: { self.wallNow },
            uptime: { self.uptime },
            powerSnapshot: { self.powerSnapshot },
            currentProcess: { ProcessIdentity(pid: 42, uid: 501, startedSeconds: 1, startedMicroseconds: 0) },
            owner: { 501 },
            makeSessionID: { self.sessionID },
            leaseDirectory: root,
            readHelperStatus: { self.status },
            helperHasFinished: { self.helperFinished ?? $0.hasFinished },
            helperNeedsRecovery: { self.helperRecovery ?? $0.needsRecovery },
            authorize: { arguments, completion in
                self.authorizationRequests.append(arguments)
                self.onAuthorize?(arguments)
                if self.holdAuthorization {
                    self.heldAuthorizationCompletion = completion
                } else {
                    completion(self.authorizationResult)
                }
            },
            takeAssertion: { kind in
                self.assertionRequests.append(kind)
                if kind == self.assertionFailure { throw AwakeError("Display assertion rejected") }
                return UInt32(self.assertionRequests.count)
            },
            releaseAssertion: { self.releasedAssertions.append($0) },
            beginActivity: { self.activityBegins += 1 },
            endActivity: { self.activityEnds += 1 }
        )
    }

    func runningStatus() -> HelperStatus {
        status(state: "running", needsRestore: true, reason: "")
    }

    func completeAuthorization() {
        let completion = heldAuthorizationCompletion
        heldAuthorizationCompletion = nil
        holdAuthorization = false
        completion?(authorizationResult)
    }

    func status(state: String, needsRestore: Bool, reason: String) -> HelperStatus {
        HelperStatus(
            sessionID: sessionID,
            owner: 501,
            helper: ProcessIdentity(pid: 1, uid: 0, startedSeconds: 0, startedMicroseconds: 0),
            state: state,
            needsRestore: needsRestore,
            started: wallNow,
            reason: reason
        )
    }

    var leaseExists: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(sessionID + ".json").path)
    }

    func advance(seconds: TimeInterval) {
        uptime += seconds
        wallNow = wallNow.addingTimeInterval(seconds)
    }

    func readLease() throws -> Lease {
        let url = root.appendingPathComponent(sessionID + ".json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Lease.self, from: data)
    }

}

private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw AwakeError(message) }
}
