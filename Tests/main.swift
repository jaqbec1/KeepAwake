import Foundation
import Darwin
import IOKit.pwr_mgt

var count = 0
func check(_ name: String, _ work: () throws -> Void) {
    do { try work(); count += 1; print("PASS \(name)") }
    catch { fputs("FAIL \(name): \(error)\n", stderr); exit(1) }
}
func require(_ value: @autoclosure () -> Bool, _ text: String = "Unexpected result") throws {
    if !value() { throw AwakeError(text) }
}
func rejects(_ work: () throws -> Void) throws {
    do { try work() } catch { return }
    throw AwakeError("Expected rejection")
}

let ac = PowerSnapshot(onAC: true, batteryPercent: 85, lidClosed: false, thermal: .nominal)
let battery = PowerSnapshot(onAC: false, batteryPercent: 85, lidClosed: true, thermal: .nominal)
var options = SessionOptions()
check("ordinary session allowed on power") { try require(SessionPolicy.stopReason(options: options, power: ac, elapsed: 0) == nil) }
check("charger-only session stops on battery") { try require(SessionPolicy.stopReason(options: options, power: battery, elapsed: 0) != nil) }
check("timer ends at the exact deadline") { try require(SessionPolicy.stopReason(options: options, power: ac, elapsed: 3600) == "Timer finished") }
check("timer stays active before the deadline") { try require(SessionPolicy.stopReason(options: options, power: ac, elapsed: 3599) == nil) }
options.chargerOnly = false
check("battery option allows a charged battery") { try require(SessionPolicy.stopReason(options: options, power: battery, elapsed: 0) == nil) }
check("battery cutoff includes the selected boundary") {
    var power = battery; power.batteryPercent = 20
    try require(SessionPolicy.stopReason(options: options, power: power, elapsed: 0) != nil)
    power.batteryPercent = 21
    try require(SessionPolicy.stopReason(options: options, power: power, elapsed: 0) == nil)
}
check("unreadable battery ends battery sessions") {
    var power = battery; power.batteryPercent = nil
    try require(SessionPolicy.stopReason(options: options, power: power, elapsed: 0) != nil)
}
check("unknown power source ends sessions") {
    var power = ac; power.onAC = nil
    try require(SessionPolicy.stopReason(options: options, power: power, elapsed: 0) != nil)
}
check("serious thermal pressure ends sessions on AC") {
    var power = ac; power.thermal = .serious
    try require(SessionPolicy.stopReason(options: options, power: power, elapsed: 0) != nil)
}
check("critical thermal pressure ends sessions on battery") {
    var power = battery; power.thermal = .critical
    try require(SessionPolicy.stopReason(options: options, power: power, elapsed: 0) != nil)
}
check("indefinite duration has no timer cutoff") {
    var option = options; option.minutes = 0
    try require(SessionPolicy.stopReason(options: option, power: ac, elapsed: 100000) == nil)
}
check("invalid durations and battery thresholds are rejected") {
    for value in [-1, 1441, Int.max] { var option = options; option.minutes = value; try rejects { try option.validate() } }
    var option = options; option.batteryFloor = 1; try rejects { try option.validate() }
}
check("closed lid does not permit display-on mode") {
    var option = options; option.mode = .closedLid; option.keepDisplayOn = true
    try rejects { try option.validate() }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("keepawake-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let leaseURL = root.appendingPathComponent("lease.json")
let sessionID = UUID().uuidString
func writeLease(_ lease: Lease) throws { try JSONEncoder().encode(lease).write(to: leaseURL, options: .atomic) }
let now = Date()
check("fresh heartbeat is accepted") {
    try writeLease(Lease(sessionID: sessionID, active: true, updated: now))
    try require(Lease.read(url: leaseURL, owner: getuid(), sessionID: sessionID, now: now)?.active == true)
}
check("stop request is accepted without extending the session") {
    try writeLease(Lease(sessionID: sessionID, active: false, updated: now))
    try require(Lease.read(url: leaseURL, owner: getuid(), sessionID: sessionID, now: now)?.active == false)
}
check("expired and future heartbeats are rejected") {
    for age in [-21.0, 60.0] {
        try writeLease(Lease(sessionID: sessionID, active: true, updated: now.addingTimeInterval(age)))
        try require(Lease.read(url: leaseURL, owner: getuid(), sessionID: sessionID, now: now) == nil)
    }
}
check("heartbeat from another session or owner is rejected") {
    try writeLease(Lease(sessionID: sessionID, active: true, updated: now))
    try require(Lease.read(url: leaseURL, owner: getuid() + 1, sessionID: sessionID, now: now) == nil)
    try require(Lease.read(url: leaseURL, owner: getuid(), sessionID: UUID().uuidString, now: now) == nil)
}
check("symlink heartbeat is rejected") {
    let linkURL = root.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: leaseURL)
    try require(Lease.read(url: linkURL, owner: getuid(), sessionID: sessionID, now: now) == nil)
}
check("oversized and malformed heartbeats are rejected") {
    for data in [Data(repeating: 0, count: 5000), Data("invalid".utf8)] {
        try data.write(to: leaseURL)
        try require(Lease.read(url: leaseURL, owner: getuid(), sessionID: sessionID, now: now) == nil)
    }
}
check("process identity includes creation time") {
    guard let identity = ProcessIdentity.read(getpid()) else { throw AwakeError("Cannot read process identity outside the sandbox") }
    try require(identity.isAlive)
    let other = ProcessIdentity(pid: identity.pid, uid: identity.uid, startedSeconds: identity.startedSeconds + 1, startedMicroseconds: identity.startedMicroseconds)
    try require(!other.isAlive)
    try require(other.hasExited)
}
check("an inaccessible root process does not trigger helper recovery") {
    // launchd exists, but an ordinary app cannot read its full BSD process info.
    let rootProcess = ProcessIdentity(pid: 1, uid: 0, startedSeconds: 0, startedMicroseconds: 0)
    try require(ProcessIdentity.read(1) == nil, "Run this check as the ordinary app user")
    try require(!rootProcess.isAlive, "Authorization must still require an exact identity match")
    var status = HelperStatus(sessionID: sessionID, owner: getuid(), helper: rootProcess, state: "running", needsRestore: true, started: Date(), reason: "")
    try require(!status.needsRecovery, "Permission denied does not mean the helper exited")
    try require(!status.hasFinished, "Keep sending heartbeats while the helper is running")
    status.state = "stopped"
    try require(status.hasFinished)
}
check("an exited process is detected and allows recovery") {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    guard let identity = ProcessIdentity.read(process.processIdentifier) else { throw AwakeError("Cannot inspect the test process") }
    try require(!identity.hasExited)
    process.terminate()
    process.waitUntilExit()
    try require(identity.hasExited)
    let status = HelperStatus(sessionID: sessionID, owner: getuid(), helper: identity, state: "running", needsRestore: true, started: Date(), reason: "")
    try require(status.hasFinished && status.needsRecovery)
}
check("helper request requires a live owner and fresh heartbeat") {
    guard let identity = ProcessIdentity.read(getpid()) else { throw AwakeError("Cannot read process identity") }
    try writeLease(Lease(sessionID: sessionID, active: true, updated: Date()))
    var option = options; option.mode = .closedLid
    let request = HelperRequest(sessionID: sessionID, parent: identity, leasePath: leaseURL.path, options: option)
    try request.validate()
    try writeLease(Lease(sessionID: sessionID, active: false, updated: Date()))
    try rejects { try request.validate() }
}
if CommandLine.arguments.contains("--live-assertion") {
    check("real idle assertion can be created and released") {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Keep Awake verification" as CFString, &id)
        try require(result == kIOReturnSuccess)
        try require(IOPMAssertionRelease(id) == kIOReturnSuccess)
    }
}
print("\(count) checks passed. Global sleep settings were not changed.")
