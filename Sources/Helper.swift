import Foundation
import Darwin

// This executable is authorized for one session. It is never registered with launchd.
final class SessionHelper {
    var descriptor: Int32 = -1
    var record: HelperStatus?
    var ownsOverride = false
    var stopping = false
    var signalSources: [DispatchSourceSignal] = []

    func lock() throws {
        let directory = AppInfo.runtimeDirectory
        if mkdir(directory, 0o755) != 0 && errno != EEXIST { throw AwakeError("Cannot create the session directory.") }
        var info = stat()
        guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == 0, info.st_mode & 0o022 == 0 else { throw AwakeError("The session directory has unsafe permissions.") }
        descriptor = open(directory + "/lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0, fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == 0, info.st_nlink == 1,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw AwakeError("A closed-lid session is already running.")
        }
    }

    func save() throws {
        guard let record else { return }
        try JSONEncoder().encode(record).write(to: AppInfo.statusURL, options: .atomic)
        chmod(AppInfo.statusURL.path, 0o644)
    }

    func restore(reason: String) {
        if ownsOverride {
            do {
                try PowerSettings.runPMSet(["-a", "disablesleep", "0"])
                guard PowerSettings.waitForBool("SleepDisabled", equals: false) else { throw AwakeError("Sleep restoration could not be verified.") }
                ownsOverride = false
                record?.needsRestore = false
                record?.state = "stopped"
                record?.reason = reason
            } catch {
                record?.state = "recoveryRequired"
                record?.reason = "Normal sleep could not be restored. Use Restore normal sleep in Keep Awake."
            }
        }
        try? save()
    }

    func run(_ request: HelperRequest) throws {
        try request.validate()
        try lock()
        guard PowerSettings.readBool("SleepDisabled") == false else {
            throw AwakeError("Sleep is already disabled by another session or app. Restore it before starting.")
        }
        guard let identity = ProcessIdentity.read(getpid()) else { throw AwakeError("Cannot identify the session helper.") }
        record = HelperStatus(sessionID: request.sessionID, owner: request.parent.uid, helper: identity, state: "starting", needsRestore: false, started: Date(), reason: "")
        try save()
        let options = request.options
        if let reason = SessionPolicy.stopReason(options: options, power: .current(), elapsed: 0) {
            record?.state = "stopped"; record?.reason = reason; try save(); return
        }

        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.stopping = true }
            source.resume()
            signalSources.append(source)
        }
        // Journal ownership before changing the global setting, including partial failure.
        record?.needsRestore = true
        try save()
        ownsOverride = true
        defer { restore(reason: record?.reason.isEmpty == false ? record!.reason : "Session ended") }
        try PowerSettings.runPMSet(["-a", "disablesleep", "1"])
        guard PowerSettings.waitForBool("SleepDisabled", equals: true) else { throw AwakeError("macOS did not confirm closed-lid mode within 3 seconds.") }
        record?.state = "running"
        try save()
        let began = ProcessInfo.processInfo.systemUptime
        var previousLid = false
        while !stopping {
            guard request.parent.isAlive else { record?.reason = "Keep Awake quit"; break }
            guard let lease = Lease.read(url: URL(fileURLWithPath: request.leasePath), owner: request.parent.uid, sessionID: request.sessionID) else {
                record?.reason = "Keep Awake stopped responding"; break
            }
            if !lease.active { record?.reason = "Stopped"; break }
            let power = PowerSnapshot.current()
            if let reason = SessionPolicy.stopReason(options: options, power: power, elapsed: ProcessInfo.processInfo.systemUptime - began) {
                record?.reason = reason; break
            }
            guard PowerSettings.readBool("SleepDisabled") == true else { record?.reason = "Sleep setting changed outside Keep Awake"; break }
            if power.lidClosed == true && !previousLid { try? PowerSettings.runPMSet(["displaysleepnow"]) }
            previousLid = power.lidClosed == true
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
    }

    func recover(owner: UInt32) throws {
        try lock()
        guard var old = HelperStatus.read(), old.owner == owner, old.needsRecovery else {
            throw AwakeError("There is no interrupted Keep Awake session to restore.")
        }
        try PowerSettings.runPMSet(["-a", "disablesleep", "0"])
        guard PowerSettings.waitForBool("SleepDisabled", equals: false) else { throw AwakeError("Normal sleep could not be restored.") }
        old.needsRestore = false; old.state = "stopped"; old.reason = "Normal sleep restored"
        record = old; try save()
    }

    deinit { if descriptor >= 0 { close(descriptor) } }
}

@main struct HelperMain {
    static func main() {
        do {
            guard geteuid() == 0 else { throw AwakeError("Start closed-lid sessions from the Keep Awake app.") }
            let args = CommandLine.arguments
            guard args.count == 3 else { throw AwakeError("Invalid helper arguments.") }
            if args[1] == "--recover", let uid = UInt32(args[2]), uid >= 500 {
                try SessionHelper().recover(owner: uid); return
            }
            guard ["--launch", "--run"].contains(args[1]),
                  let data = Data(base64Encoded: args[2]), data.count <= 4096 else { throw AwakeError("Invalid session request.") }
            let request = try JSONDecoder().decode(HelperRequest.self, from: data)
            try request.validate()
            if args[1] == "--run" {
                let helper = SessionHelper()
                do { try helper.run(request) }
                catch {
                    if helper.record != nil {
                        helper.record?.reason = error.localizedDescription
                        if !helper.ownsOverride && helper.record?.needsRestore == false { helper.record?.state = "stopped" }
                        try? helper.save()
                    }
                    throw error
                }
            } else {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: args[0]).standardizedFileURL
                child.arguments = ["--run", args[2]]
                child.standardInput = FileHandle.nullDevice
                child.standardOutput = FileHandle.nullDevice
                child.standardError = FileHandle.nullDevice
                try child.run()
                // Detach only after the worker has verified activation or reported failure.
                // Allow the bounded command/confirmation waits and failure cleanup to finish.
                for _ in 0..<300 {
                    if let state = HelperStatus.read(), state.sessionID == request.sessionID {
                        if state.state == "running" { return }
                        if state.state == "stopped" || state.state == "recoveryRequired" { throw AwakeError(state.reason) }
                    }
                    if !child.isRunning { throw AwakeError("The session could not start. Another app may already control sleep.") }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                child.terminate()
                throw AwakeError("The session did not start in time. Check its status before trying again.")
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
