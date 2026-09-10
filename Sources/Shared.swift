import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Darwin

enum AppInfo {
    static let identifier = "sh.holistic.keepawake"
    static let version = "1.1.0"
    static let runtimeDirectory = "/private/var/run/sh.holistic.keepawake"
    static let statusURL = URL(fileURLWithPath: runtimeDirectory).appendingPathComponent("session.json")
}

enum SessionMode: String, Codable, CaseIterable {
    case ordinary, closedLid
    var title: String { self == .ordinary ? "Keep Mac awake" : "Keep awake with lid closed" }
}

struct SessionOptions: Codable, Equatable {
    var mode: SessionMode = .ordinary
    var minutes: Int = 60
    var chargerOnly = true
    var batteryFloor = 20
    var keepDisplayOn = false

    func validate() throws {
        guard minutes == 0 || (1...1440).contains(minutes) else { throw AwakeError("Choose a duration between 1 minute and 24 hours, or Until stopped.") }
        guard [10, 20, 30, 40, 50].contains(batteryFloor) else { throw AwakeError("Invalid battery cutoff.") }
        guard mode != .closedLid || !keepDisplayOn else { throw AwakeError("Closed-lid mode allows the display to sleep.") }
    }
}

struct PowerSnapshot {
    var onAC: Bool?
    var batteryPercent: Int?
    var lidClosed: Bool?
    var thermal: ProcessInfo.ThermalState

    static func current() -> PowerSnapshot {
        var onAC: Bool?
        var percent: Int?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            if let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
                if type == kIOPSACPowerValue { onAC = true }
                if type == kIOPSBatteryPowerValue { onAC = false }
            }
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
            for item in list {
                guard let data = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                      data[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = data[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = data[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                percent = max(0, min(100, Int(Double(current) / Double(maximum) * 100)))
            }
        }
        return PowerSnapshot(onAC: onAC, batteryPercent: percent, lidClosed: PowerSettings.readBool("AppleClamshellState"), thermal: ProcessInfo.processInfo.thermalState)
    }

    var description: String {
        let battery = batteryPercent.map { " · \($0)%" } ?? ""
        if onAC == true { return "Power adapter\(battery)" }
        if onAC == false { return "Battery\(battery)" }
        return "Power source unavailable"
    }
}

enum SessionPolicy {
    static func stopReason(options: SessionOptions, power: PowerSnapshot, elapsed: TimeInterval) -> String? {
        if options.minutes > 0 && elapsed >= Double(options.minutes * 60) { return "Timer finished" }
        if power.thermal == .serious || power.thermal == .critical { return "Stopped because the Mac is too warm" }
        guard let onAC = power.onAC else { return "Power source could not be read" }
        if options.chargerOnly && !onAC { return "Connect the power adapter to continue" }
        if !onAC {
            guard let battery = power.batteryPercent else { return "Battery level could not be read" }
            if battery <= options.batteryFloor { return "Battery reached the \(options.batteryFloor)% cutoff" }
        }
        return nil
    }
}

struct AwakeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum PowerSettings {
    static func readBool(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    static func waitForBool(_ key: String, equals expected: Bool, timeout: TimeInterval = 3) -> Bool {
        // pmset returns after saving preferences; powerd applies them asynchronously.
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if readBool(key) == expected { return true }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            Thread.sleep(forTimeInterval: min(0.05, remaining))
        }
    }

    static func runPMSet(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + 8) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw AwakeError("macOS did not respond to the power-setting request.")
        }
        guard process.terminationStatus == 0 else { throw AwakeError("macOS rejected the power-setting request.") }
    }
}

struct ProcessIdentity: Codable, Equatable {
    let pid: Int32
    let uid: UInt32
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64

    static func read(_ pid: Int32) -> ProcessIdentity? {
        var value = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, size) == size else { return nil }
        return ProcessIdentity(pid: pid, uid: value.pbi_uid, startedSeconds: value.pbi_start_tvsec, startedMicroseconds: value.pbi_start_tvusec)
    }
    var isAlive: Bool { Self.read(pid) == self }

    var hasExited: Bool {
        if let current = Self.read(pid) { return current != self }
        // Unprivileged apps cannot inspect root helpers. EPERM is not an exit.
        guard pid > 0 else { return true }
        errno = 0
        return Darwin.kill(pid, 0) == -1 && errno == ESRCH
    }
}

enum BootClock {
    static func identifier() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
              size > 1, size <= 128 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }
}

struct Lease: Codable {
    var sessionID: String
    var active: Bool
    // Keep the wall timestamp so older helpers can decode new leases. New helpers
    // require the boot-scoped fields below and reject old wall-clock-only leases.
    var updated: Date
    var bootID: String
    var updatedUptime: TimeInterval

    init(sessionID: String, active: Bool, updated: Date, bootID: String = BootClock.identifier() ?? "", updatedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.sessionID = sessionID
        self.active = active
        self.updated = updated
        self.bootID = bootID
        self.updatedUptime = updatedUptime
    }

    static func read(url: URL, owner: uid_t, sessionID: String, now: Date = Date(), bootID: String? = BootClock.identifier(), uptime: TimeInterval? = nil) -> Lease? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var details = stat()
        guard fstat(descriptor, &details) == 0,
              (details.st_mode & S_IFMT) == S_IFREG,
              details.st_uid == owner, details.st_nlink == 1,
              details.st_size > 0, details.st_size <= 4096 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count > 0,
              let lease = try? JSONDecoder().decode(Lease.self, from: Data(bytes.prefix(count))),
              lease.sessionID == sessionID,
              let bootID, !bootID.isEmpty, lease.bootID == bootID else { return nil }
        let observedUptime = uptime ?? ProcessInfo.processInfo.systemUptime
        guard
              observedUptime >= lease.updatedUptime,
              observedUptime - lease.updatedUptime < 20 else { return nil }
        return lease
    }
}

struct HelperRequest: Codable {
    var sessionID: String
    var parent: ProcessIdentity
    var leasePath: String
    var options: SessionOptions

    func validate() throws {
        try options.validate()
        guard UUID(uuidString: sessionID) != nil,
              options.mode == .closedLid,
              parent.uid >= 500, parent.pid > 1,
              parent.isAlive,
              leasePath.hasPrefix("/"), leasePath.utf8.count < 1024,
              let lease = Lease.read(url: URL(fileURLWithPath: leasePath), owner: parent.uid, sessionID: sessionID), lease.active else {
            throw AwakeError("The session request is invalid or has expired. Start it again from Keep Awake.")
        }
    }
}

struct HelperStatus: Codable {
    var sessionID: String
    var owner: UInt32
    var helper: ProcessIdentity
    var state: String
    var needsRestore: Bool
    var started: Date
    var reason: String

    static func read() -> HelperStatus? {
        guard let data = try? Data(contentsOf: AppInfo.statusURL), data.count <= 8192 else { return nil }
        return try? JSONDecoder().decode(HelperStatus.self, from: data)
    }

    var hasFinished: Bool { state == "stopped" || state == "recoveryRequired" || helper.hasExited }
    var needsRecovery: Bool { needsRestore && (state == "recoveryRequired" || helper.hasExited) }
}
