# Keep Awake privileged lifecycle review

Reviewed main `dced7ae262e909ef19e8b248e553a8ec9e3ea86f`, 10 September 2026. Read-only source review plus isolated unprivileged Swift probes. No power settings changed, no actual session started or stopped. Applied the installed unslop skill.

## Confirmed behavior defects

### 1. A clock correction can reject a healthy heartbeat

P2, high confidence. `Sources/Shared.swift:153–168` measures lease age with `Date`, and `Sources/App.swift:185` supplies a wall-clock timestamp. If the system clock steps forward by more than 20 seconds or backward by more than 5 seconds between a write and the helper read, the next helper poll rejects a fresh lease. `Sources/Helper.swift:83–85` then ends the user's session as "stopped responding" and restores sleep. A clock correction during a closed-lid job can interrupt the job even though both processes are healthy. Time-zone changes alone do not change Date and are not a trigger.

The isolated `lease_probe.swift` compiled against unchanged `Sources/Shared.swift` accepted the same freshly written file at offset 0 and rejected it at +21 and -6 seconds. No system clock change was needed.

Use a monotonic boot-scoped lease timestamp or sequence number, with the helper tracking elapsed time since an observed update. Keep the session UUID and file ownership checks. Acceptance: simulated wall-clock changes do not end a healthy session, but 20 seconds without a new heartbeat still does.

### 2. Recovery can stay hidden after a helper PID is reused by an inaccessible root process

P2, medium confidence for real occurrence, high confidence in the conditional behavior. `Sources/Shared.swift:139–144` correctly treats denied process inspection as unknown. However, `Sources/Shared.swift:207` requires confirmed exit before offering recovery, even for a journal already marked `recoveryRequired`. `Sources/App.swift:243–245` copies that decision into the UI. If a helper exits and its PID is reused by a root process before the app checks, the GUI cannot establish the start-time mismatch and `kill(pid, 0)` returns EPERM. Recovery can remain unavailable until the unrelated process exits.

The isolated probe used PID 1 as an existing inaccessible root process and a deliberately mismatched stored identity. It produced `hasExited=false` and `needsRecovery=false` for a `recoveryRequired` journal. This simulates the post-reuse state; it does not reproduce a natural PID reuse sequence.

Separate "definitely exited" from "may need recovery". An explicit recovery attempt can authorize the helper and let its existing nonblocking root lock arbitrate safely. It must never reset settings while another legitimate helper owns the lock. Acceptance: inaccessible reused PID does not prevent recovery after the lock is free, and a genuinely active helper remains protected.

## Highest-priority runtime gaps

### App Nap can invalidate the GUI heartbeat

Strong code and OS evidence, not a reproduced App Nap failure. `Sources/App.swift:47–51` runs the heartbeat on an ordinary main-run-loop Timer. Closed-lid activation at `Sources/App.swift:132–159` creates neither an IOKit assertion for the GUI nor a retained ProcessInfo activity. The assertion path at `Sources/App.swift:106–108` only runs for ordinary sessions. Once authorization returns, the menu utility is normally a background app with no visible window. The root helper keeping the machine awake does not itself document a guarantee that this separate GUI process will avoid App Nap.

Apple lists apps without IOKit or NSProcessInfo assertions among App Nap candidates and explains that App Nap throttles timers. A heartbeat delay longer than 20 seconds makes `Sources/Helper.swift:83–85` terminate the session. The 30-second activation test does not establish hours of reliability under a locked screen or closed lid. [Apple App Nap guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html).

Retain an appropriate user-initiated ProcessInfo activity while starting, running, and completing restoration, then end it. Choose an option that lets the display sleep and does not introduce unwanted power behavior. [Apple activity guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheAppLevel.html).

Acceptance: physical lid-close and locked-screen tests for at least 30 minutes, including battery operation and App Nap observation, show no heartbeat gap near the expiry threshold. Stop and restoration must still complete. Record actual timings rather than relying on process existence.

### Recovery journal durability across an abrupt reboot is unproven

High-impact acceptance gap, not a verified current-macOS reboot defect. `Sources/Shared.swift:10–11` stores the only ownership journal under `/private/var/run`. `Sources/Helper.swift:70–75` saves it before setting disablesleep, but `Sources/Helper.swift:28` uses an atomic Foundation write without an explicit durable commit protocol. `Sources/App.swift:245` offers recovery only when this journal exists. Missing ownership evidence makes `Sources/Helper.swift:100–102` refuse recovery.

Do not assume `disablesleep` necessarily resets on reboot. Apple's pmset source explicitly saves system-wide settings to disk at lines 790–803 and treats disablesleep as a system setting at lines 5818–5838. powerd reads those preferences and publishes SleepDisabled at PMSettings.m lines 1336–1347. [Apple pmset source](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m#L790), [Apple powerd source](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmconfigd/PMSettings.m#L1336).

The local Apple `hier(7)` manual describes `/var/run` as state since boot. This review did not establish the exact current macOS cleanup path for this custom directory, nor test abrupt power loss. The conditional failure is clear: if the override survives and the journal does not, Keep Awake cannot offer its normal owned-session recovery. A boot-scoped PID identity also needs care if a journal is made durable.

Acceptance: on a disposable Mac or VM, preserve actual settings and journal evidence across helper SIGKILL, forced app exit, orderly restart, and abrupt restart. If settings can survive a lost journal, move recovery ownership to a durable root-owned location and use a boot identifier. Keep runtime locks separate. Define how the app reports an enabled override with missing or invalid ownership without silently resetting another utility's settings.

## Explicit product and security decisions

- Killing the root helper bypasses all cleanup and all battery/thermal checks. The app offers manual recovery only after detecting the helper's exit. This follows `Sources/Helper.swift:74` and the documented design in README lines 43–45. It is a real residual risk, not a newly discovered regression. Decide whether manual recovery is acceptable for unattended indefinite closed-lid sessions.
- The authorized command executes a bundled helper from a user-writable app location, `Sources/App.swift:164–170`, and that helper reexecutes its path at `Sources/Helper.swift:137–143`. The current design trusts code and files writable by the same user. Administrator approval is approval to run that executable as root; it does not establish a robust boundary against already-running malicious code under the same user. No exploit was attempted. A broader hostile-local-process threat model needs an authenticated, protected privileged component and a narrower request protocol. This is beyond release signing alone.
- Other utilities can change the same global flag between checks and restoration. The lock arbitrates Keep Awake helpers only. README already discloses this; neither a local lock nor a saved baseline can fully arbitrate a single unowned system boolean.

## Candidates ruled out

- Empty run-loop CPU spin was not reproduced. `runloop.swift` installs the same SIGTERM/SIGINT/SIGHUP DispatchSourceSignal objects and calls `RunLoop.current.run(until: +1 second)`. It completed one iteration in 1.0088 seconds. `Sources/Helper.swift:94` therefore waits in this isolated environment.
- NSAppleScript on a background queue is not by itself a confirmed bug. Apple DTS says the main-thread-only limitation was lifted in macOS 10.6 and recommends serializing use. The model's phase guard currently serializes authorization operations. [Apple DTS, July 2024](https://developer.apple.com/forums/thread/759287).
- A mandatory prompt bypass due to the AppleScript five-minute cache is not established. Apple's TN2065 says changing a script requires its own authentication, and every start includes a new session UUID. [Apple TN2065](https://developer.apple.com/library/archive/technotes/tn2065/_index.html).
- Shell arguments are quoted and AppleScript string metacharacters are escaped. The root helper bounds and validates the request, verifies exact parent identity, uses a root-owned nonwritable runtime directory and exclusive lock, and reads only a bounded owner-matched regular heartbeat file. No concrete command-injection or cross-user file-write exploit was identified in this bounded review.

## Suggested order

1. Complete physical Stop/restoration, locked-screen, and App Nap acceptance tests. Add a scoped activity token if this mode is intended for unattended work.
2. Replace wall-clock lease expiry and add the clock-step regression.
3. Permit a safe lock-arbitrated recovery attempt when process identity is inaccessible. Preserve the EPERM fix.
4. Establish reboot persistence on disposable hardware, then choose a durable journal and boot identity if needed.
5. Decide whether helper-crash manual recovery and same-user code trust meet the intended personal-use threat model before changing the privilege architecture.

Graph context was Verify tier, KeepAwake generation `2026-09-09T21:42:55Z`. All four Swift files reported metadata changes, so findings use directly read current source. The helper run trace had no pagination, but also included heuristic false callers; it was not treated as authoritative call-site evidence. No repository source files were edited.
