"""Run the real helper loop against isolated fake macOS power services.

Only OS boundaries are replaced in a temporary build: power reads/writes,
root ownership, the runtime folder, and the timer scale. The released build
contains none of these replacements. No global sleep settings are changed.
"""
import base64
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time

project = Path(__file__).resolve().parents[1]
apple_epoch = 978307200

with tempfile.TemporaryDirectory(prefix='keepawake-helper-test-') as temporary:
    root = Path(temporary)
    shared = (project / 'Sources/Shared.swift').read_text()
    shared = shared.replace('static let runtimeDirectory = "/private/var/run/sh.holistic.keepawake"', 'static let runtimeDirectory = ProcessInfo.processInfo.environment["TEST_RUNTIME"]!')
    shared = shared.replace('Double(options.minutes * 60)', 'Double(options.minutes)')
    start = shared.index('    static func current() -> PowerSnapshot {')
    end = shared.index('    var description: String {', start)
    shared = shared[:start] + '''    static func current() -> PowerSnapshot {
        let data = try! Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_POWER"]!))
        let info = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return PowerSnapshot(onAC: info["ac"] as? Bool, batteryPercent: info["battery"] as? Int, lidClosed: false, thermal: .nominal)
    }
''' + shared[end:]
    confirmation_start = shared.index('    static func waitForBool(')
    confirmation_end = shared.index('    static func runPMSet(', confirmation_start)
    confirmation = shared[confirmation_start:confirmation_end]
    start = shared.index('enum PowerSettings {')
    end = shared.index('struct ProcessIdentity:', start)
    shared = shared[:start] + '''enum PowerSettings {
    static var url: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_OVERRIDE"]!) }
    static var pending: (value: String, ready: TimeInterval)?
    static func readBool(_ key: String) -> Bool? {
        guard key == "SleepDisabled" else { return false }
        if let update = pending, ProcessInfo.processInfo.systemUptime >= update.ready {
            try! update.value.write(to: url, atomically: true, encoding: .utf8)
            pending = nil
        }
        return (try? String(contentsOf: url, encoding: .utf8)) == "1"
    }
''' + confirmation + '''    static func runPMSet(_ arguments: [String]) throws {
        if arguments == ["displaysleepnow"] { return }
        guard arguments.count == 3, arguments[0] == "-a", arguments[1] == "disablesleep" else { throw AwakeError("Unexpected power command") }
        let value = arguments[2]
        let environment = ProcessInfo.processInfo.environment
        let delay = Double(environment[value == "1" ? "TEST_ENABLE_DELAY" : "TEST_RESTORE_DELAY"] ?? "0")!
        if environment[value == "1" ? "TEST_IGNORE_ENABLE" : "TEST_IGNORE_RESTORE"] != "1" {
            if delay > 0 { pending = (value, ProcessInfo.processInfo.systemUptime + delay) }
            else { try value.write(to: url, atomically: true, encoding: .utf8); pending = nil }
        }
        if arguments[2] == "1" && ProcessInfo.processInfo.environment["TEST_ENABLE_ERROR"] == "1" { throw AwakeError("Simulated partial activation failure") }
    }
}

''' + shared[end:]
    helper = (project / 'Sources/Helper.swift').read_text()
    helper = helper.replace('info.st_uid == 0', 'info.st_uid == getuid()')
    helper = helper.replace('guard geteuid() == 0 else', 'guard geteuid() == getuid() else')
    (root / 'Shared.swift').write_text(shared)
    (root / 'Helper.swift').write_text(helper)
    (root / 'Owner.swift').write_text('''import Foundation
import Darwin
@main struct Owner {
    static func main() {
        let identity = ProcessIdentity.read(getpid())!
        print(String(data: try! JSONEncoder().encode(identity), encoding: .utf8)!)
        fflush(stdout)
        while true { Thread.sleep(forTimeInterval: 1) }
    }
}
''')
    for source, binary in [('Helper.swift', 'helper'), ('Owner.swift', 'owner')]:
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(project / 'build/module-cache'), str(root / 'Shared.swift'), str(root / source), '-o', str(root / binary)], check=True)

    def wait_for(check, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                if check():
                    return
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(.05)
        raise AssertionError('Expected state did not arrive')

    def run_case(name, action, *, minutes=0, charger=True, enable_error=False, enable_delay=0, restore_delay=0, ignore_enable=False, ignore_restore=False):
        import uuid
        if os.environ.get('KEEP_AWAKE_TEST_CASE') not in (None, name):
            return
        folder = root / name
        folder.mkdir()
        runtime = folder / 'runtime'
        override = folder / 'override'
        power = folder / 'power.json'
        lease = folder / 'lease.json'
        override.write_text('0')
        power.write_text(json.dumps({'ac': True, 'battery': 80}))
        owner = subprocess.Popen([str(root / 'owner')], stdout=subprocess.PIPE, text=True)
        identity = json.loads(owner.stdout.readline())
        session = str(uuid.uuid4())
        def heartbeat(active=True, age=0):
            temp = folder / 'new.json'
            temp.write_text(json.dumps({'sessionID': session, 'active': active, 'updated': time.time() - apple_epoch + age}))
            temp.replace(lease)
        heartbeat()
        request = {'sessionID': session, 'parent': identity, 'leasePath': str(lease), 'options': {'mode': 'closedLid', 'minutes': minutes, 'chargerOnly': charger, 'batteryFloor': 20, 'keepDisplayOn': False}}
        payload = base64.b64encode(json.dumps(request).encode()).decode()
        env = {**os.environ, 'TEST_RUNTIME': str(runtime), 'TEST_OVERRIDE': str(override), 'TEST_POWER': str(power), 'TEST_ENABLE_ERROR': '1' if enable_error else '0', 'TEST_ENABLE_DELAY': str(enable_delay), 'TEST_RESTORE_DELAY': str(restore_delay), 'TEST_IGNORE_ENABLE': '1' if ignore_enable else '0', 'TEST_IGNORE_RESTORE': '1' if ignore_restore else '0'}
        process = subprocess.Popen([str(root / 'helper'), '--run', payload], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            if not enable_error and not ignore_enable:
                wait_for(lambda: json.loads((runtime / 'session.json').read_text())['state'] == 'running')
                action(process, owner, heartbeat, power)
            out, err = process.communicate(timeout=10)
            record = json.loads((runtime / 'session.json').read_text())
            assert override.read_text() == ('1' if ignore_restore else '0'), (name, 'unexpected final override', err)
            assert record['needsRestore'] == ignore_restore, (name, record)
            assert record['state'] == ('recoveryRequired' if ignore_restore else 'stopped'), (name, record)
            assert process.returncode == (1 if enable_error or ignore_enable else 0), (name, err)
            if ignore_enable:
                assert 'did not confirm' in record['reason'], (name, record)
            print('PASS', name, flush=True)
        finally:
            if process.poll() is None:
                process.kill(); process.wait()
            if owner.poll() is None:
                owner.kill(); owner.wait()

    run_case('stop_request_restores_sleep', lambda process, owner, heartbeat, power: heartbeat(False))
    run_case('app_crash_restores_sleep', lambda process, owner, heartbeat, power: (owner.kill(), owner.wait()))
    run_case('stale_heartbeat_restores_sleep', lambda process, owner, heartbeat, power: heartbeat(age=-30))
    run_case('helper_termination_restores_sleep', lambda process, owner, heartbeat, power: process.send_signal(signal.SIGTERM))
    run_case('timer_expiry_restores_sleep', lambda *args: None, minutes=1)
    run_case('charger_loss_restores_sleep', lambda process, owner, heartbeat, power: power.write_text(json.dumps({'ac': False, 'battery': 80})))
    run_case('battery_floor_restores_sleep', lambda process, owner, heartbeat, power: power.write_text(json.dumps({'ac': False, 'battery': 20})), charger=False)
    run_case('partial_activation_restores_sleep', lambda *args: None, enable_error=True)
    run_case('delayed_activation_is_confirmed', lambda process, owner, heartbeat, power: heartbeat(False), enable_delay=.4)
    run_case('delayed_restoration_is_confirmed', lambda process, owner, heartbeat, power: heartbeat(False), restore_delay=.4)
    run_case('unconfirmed_activation_fails_and_restores', lambda *args: None, ignore_enable=True)
    run_case('unconfirmed_restoration_requires_recovery', lambda process, owner, heartbeat, power: heartbeat(False), ignore_restore=True)
print('Selected helper integration checks passed without changing macOS power settings.')
