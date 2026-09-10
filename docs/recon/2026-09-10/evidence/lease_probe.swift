import Foundation
import Darwin
@main struct Probe {
 static func main() throws {
    let url = URL(fileURLWithPath: "/private/tmp/keepawake-recon/lease-probe.json")
    defer { try? FileManager.default.removeItem(at: url) }
    let id = UUID().uuidString, now = Date()
    try JSONEncoder().encode(Lease(sessionID: id, active: true, updated: now)).write(to: url, options: .atomic)
    for offset in [0.0, 21.0, -6.0] {
        let accepted = Lease.read(url: url, owner: getuid(), sessionID: id, now: now.addingTimeInterval(offset)) != nil
        print("same freshly written heartbeat; wall-clock offset \(offset)s accepted=\(accepted)")
    }
    let inaccessibleRoot = ProcessIdentity(pid: 1, uid: 0, startedSeconds: 1, startedMicroseconds: 1)
    let status = HelperStatus(sessionID: id, owner: getuid(), helper: inaccessibleRoot, state: "recoveryRequired", needsRestore: true, started: now, reason: "Probe only")
    print("inaccessible root PID hasExited=\(inaccessibleRoot.hasExited); recoveryRequired journal needsRecovery=\(status.needsRecovery)")
 }
}
