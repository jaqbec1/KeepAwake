import Foundation
import Darwin
var signalSources: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT, SIGHUP] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { print("received") }
    source.resume()
    signalSources.append(source)
}
let start = ProcessInfo.processInfo.systemUptime
var calls = 0
while ProcessInfo.processInfo.systemUptime - start < 1.0 {
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    calls += 1
}
print("runloop calls in one second: \(calls), elapsed: \(ProcessInfo.processInfo.systemUptime - start)")
withExtendedLifetime(signalSources) {}
