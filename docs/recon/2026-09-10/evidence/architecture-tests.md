# Keep Awake architecture and test assessment

Reviewed `main` at `dced7ae262e909ef19e8b248e553a8ec9e3ea86f`, product version 1.0.2, on 10 September 2026. The supplied graph snapshot was generation `2026-09-09T21:42:55Z`, with 229 nodes and 818 edges. Its relevant source and test paths were marked `metadata_changed`, so every material claim below comes from the current files. The repository has no `CONTEXT.md` or ADR folder; names follow `PRODUCT.md` and the source.

## Verdict

The test count gave a false sense of breadth. The 35 safe checks that pass today cover policy, file validation, and a modified helper process well enough to catch several failures inside those areas. They do not execute the app's closed-lid lifecycle. That is where the 1.0.2 failure occurred. They also replace the power module before compiling the helper, so they cannot prove that production wiring works.

The best next change is a testable session lifecycle module used unchanged by the app and helper. Keep `AwakeModel` as a `@MainActor` UI facade. Put lifecycle state and transitions behind one small interface, and inject adapters only where macOS state prevents deterministic tests. Compile those exact production modules in an Xcode test target.

This is an architecture recommendation. I found no reproducible runtime defect in the current safe paths. I did confirm one build compatibility defect: the app target fails in Swift 6 language mode at `Sources/App.swift:179` because the authorization callback crosses queues without a sendable, actor-isolated contract.

## Why 30-plus tests missed two app failures

### The suite measures assertions, not exercised product paths

`Tests/main.swift` has 23 safe checks. Thirteen cover `SessionPolicy` and option validation at lines 18-60. Ten cover leases, process identity, helper status, and request validation at lines 62-139. `scripts/test.sh:5` compiles only `Sources/Shared.swift` and `Tests/main.swift`. It never compiles `Sources/App.swift`, `Sources/Menu.swift`, or `Sources/Helper.swift`.

`Tests/helper_integration.py` adds 12 scenarios, but it compiles copied and rewritten versions of `Shared.swift` and `Helper.swift` at lines 20-81. It does not compile `App.swift` or `Menu.swift`. A large number of checks can therefore stay green while app orchestration is broken.

### The failure fixed in version 1.0.2 lived in an unexecuted path

The app reads root helper status in `AwakeModel.tick()` at `Sources/App.swift:217-240`. The earlier behavior treated an unreadable root process as exited, which made the app stop its heartbeat immediately after successful activation. The Python helper tests cannot reproduce that topology:

- They replace root ownership with the current user at `Tests/helper_integration.py:64-66`.
- They run the helper directly with `--run` at line 117, skipping the `--launch` worker path in `Sources/Helper.swift:136-155`.
- They never construct or tick `AwakeModel`.

The new direct regression at `Tests/main.swift:106-116` proves `HelperStatus.hasFinished` handles PID 1 correctly on this Mac. It still does not prove the app stays in `.running` and continues writing an active lease. That missing behavior test explains how a local fix can pass while the product path remains exposed to future regressions.

### The failure fixed in version 1.0.1 required a timing fault the original test set did not model

The production code now waits for `SleepDisabled` at `Sources/Helper.swift:75-78`, using the bounded confirmation loop at `Sources/Shared.swift:95-104`. The Python runner now models delayed state changes at `Tests/helper_integration.py:40-59` and checks delayed activation and restoration at lines 145-146. Those are useful regression cases.

They were added after the failure was understood. The Git repository contains one squashed feature commit for these files, so it cannot show the exact pre-fix test content. What the current source does prove is that ordinary policy checks had no way to catch asynchronous `pmset` application, and the helper runner needed an explicit delayed adapter to reproduce it.

### The Python source rewrite is useful, but structurally weak

The runner executes much of the helper loop and leaves file leases, process identity, signals, and status persistence real. That has value. Its weak points are specific:

- Lines 22-68 edit Swift as raw text. The compiled input is not the production source file.
- The `str.replace` calls at lines 23-24 and 65-66 do not assert that a replacement occurred. A source edit can silently remove a test substitution or alter too many occurrences.
- Lines 25-63 replace entire implementations by locating text markers. Formatting or declaration changes can break the runner before Swift type checking explains the mismatch.
- Lines 27-32 force `lidClosed` to `false`, and line 50 discards `displaysleepnow`. No test covers the documented lid-close behavior in `Sources/Helper.swift:92-93`.
- Line 24 changes every matching duration expression from minutes to seconds. The test product therefore has different time semantics.
- Line 81 places the module cache in the repository's ignored `build/` directory, despite all generated Swift sources and binaries living in the temporary directory.
- The runner exercises `SessionHelper.run`, but not app authorization, launcher detachment, app heartbeat updates, app stop-to-idle confirmation, login registration, or termination handling.

Keep this runner until equivalent tests exist. Replace it case by case with tests against unchanged modules. Deleting all 12 scenarios at once would discard good failure cases.

## Architecture assessment

### Preserve the modules that already have depth

`SessionPolicy.stopReason` at `Sources/Shared.swift:67-79` is a deep module. Its small interface keeps timer, thermal, charger, unknown-power, and battery-cutoff rules identical in both the app and helper. The deletion test says to keep it: removing it would duplicate those rules in `AwakeModel` and `SessionHelper`.

`SessionHelper.run` at `Sources/Helper.swift:49-96` also has useful locality. It owns journal-before-change, activation confirmation, heartbeat monitoring, stop policy, lid transitions, and deferred restoration. Splitting each operation into a new shallow module would make the call graph harder to follow. Keep the lifecycle together and supply its external state through a small number of real seams.

### Deepen the app lifecycle

`AwakeModel` currently combines persisted settings, UI state, timers, IOKit assertions, helper authorization, file leases, helper status, recovery, and login registration at `Sources/App.swift:8-277`. Its effective interface includes the ordering rules among `phase`, `activeOptions`, `leaseURL`, `sessionID`, `stoppingSince`, `remaining`, `needsRecovery`, callbacks, and global singletons. Tests cannot drive the closed-lid lifecycle without launching macOS UI and privilege flows.

Deepen this into a session lifecycle module. Its interface should accept commands such as start, stop, and timer/status events, then return or publish a typed state. `AwakeModel` should translate menu actions into those commands and render the state. This concentrates transition bugs in one module and lets tests use the same interface as the app.

Recommendation strength: Strong.

### Make lifecycle and helper status typed

`Phase` is an enum at `Sources/App.swift:6`, but the associated data lives in independent optionals at lines 27-32. The type permits impossible combinations such as `.running` without options or `.idle` with a session ID. `HelperStatus.state` is a raw `String` at `Sources/Shared.swift:192-207`, and callers compare string literals in `Sources/App.swift:153`, `Sources/Helper.swift:39-42`, and `Sources/Helper.swift:147-149`.

Use associated values for the app lifecycle and a `Codable` helper-state enum. Keep persistent status backward compatible by decoding the current strings. The compiler should make every transition handle starting, running, stopping, stopped, and recovery-required states. Do not turn user-facing reasons into enum cases; keep a typed state plus a reason string.

Recommendation strength: Strong.

### Add seams only for state outside the process

Three seams earn their keep because production and test adapters already need different behavior:

1. Power interaction. Include the power snapshot, sleep-setting read/change/confirmation, and display-sleep request. Production uses IOKit and `pmset`; tests use a deterministic adapter that can delay, reject, or ignore changes.
2. Process observation. Return a typed observation that distinguishes the same process, a reused identity, an inaccessible but existing process, and a missing process. Production uses `proc_pidinfo` plus `kill(pid, 0)`; tests select each result directly.
3. Time and scheduling. Supply wall time, uptime, and ticks through one timing adapter. Production uses a monotonic clock and the main run loop; tests advance time without changing `minutes * 60` in copied source.

File URLs and `UserDefaults` can be injected as concrete values or isolated suites. They do not each need a protocol. Apple specifically recommends the smallest change around stateful SDK dependencies and singleton injection. The architecture should follow that advice without creating an interface for every Foundation call.

Recommendation strength: Strong for the first two seams, Worth exploring for a timing adapter during the lifecycle extraction.

## Concurrency assessment

`@MainActor` on `AwakeModel` and `AppDelegate` is appropriate. UI state is mutable and all menu rendering belongs on the main actor. The helper is a single process loop whose signal sources run on its main queue; it compiles cleanly in Swift 6 on the current machine. An actor rewrite would add work without addressing a demonstrated race.

The authorization callback is the concrete exception. A compile with Swift 5 plus `-warn-concurrency -strict-concurrency=complete` succeeds with two diagnostics at `Sources/App.swift:179`: capture of a non-Sendable completion and a possible cross-isolation race. The same app compile with `-swift-version 6` fails on the second diagnostic. Convert that operation to an `async` function that performs the blocking AppleScript work off the main actor and returns a sendable result, or give the callback an explicit `@MainActor @Sendable` contract. Keep the change narrow and rerun complete checking in Swift 5 before changing the language mode.

`Timer` plus `MainActor.assumeIsolated` at `Sources/App.swift:47-50` is consistent with a timer installed on `RunLoop.main`. Replacing the timer becomes useful for deterministic lifecycle tests. It is not a confirmed concurrency bug.

## Build and test structure

The smallest first step is a production controller module with injected time, power, and helper adapters, compiled directly by tests. No SwiftUI rewrite or dependency-injection framework is warranted.

An Xcode project is a sensible later build-system evolution because the product is an AppKit app bundle with a copied, separately signed helper and resources. Xcode targets and build phases represent those concerns directly. A SwiftPM-only build would still need custom packaging and signing scripts. The target layout below is optional and should follow the production test seam, rather than block it.

Recommended targets:

- `KeepAwakeCore`: session options, policy, lease/status values, typed lifecycle, and external-state interfaces.
- `KeepAwakeApp`: AppKit menu, `AwakeModel`, authorization adapter, IOKit assertion adapter, login item adapter, and the app entry point.
- `KeepAwakeHelper`: helper process entry point and production power/process/file adapters.
- `KeepAwakeCoreTests`: fast behavior tests with deterministic adapters.
- `KeepAwakeAppTests`: `@MainActor` lifecycle and facade tests that compile the real app module.
- `KeepAwakeHelperIntegrationTests`: subprocess and file integration tests using unchanged helper modules plus explicit test adapters.
- `KeepAwakeUITests`: one menu start/stop smoke flow when the UI target is stable.

Use one default `Safe` test plan for unit and isolated integration tests. Add a separately invoked `Privileged hardware` plan for live assertions, administrator authorization, real `pmset`, and physical lid checks. The default plan must never mutate global sleep settings. Enable code coverage and Main Thread Checker in the safe plan; run Thread Sanitizer in a CI or pre-release configuration when it is stable.

XCTest is sufficient for this migration and integrates with Xcode schemes, test plans, async test methods, expectations, and UI tests. Apple now suggests Swift Testing for new unit tests, and both systems can coexist. Test syntax is secondary here. Compiling unchanged production modules and exercising lifecycle behavior matters first. If the project adopts Swift Testing later, keep XCTest for UI automation and migrate incrementally.

A local Swift package for `KeepAwakeCore` can work if command-line `swift test` is a firm requirement. At the present size, one Xcode build graph is simpler. Avoid maintaining both an Xcode copy of the core sources and a package copy.

## Highest-value behavior regressions

Add these vertically. Write one failing test, make the smallest seam or lifecycle change that makes it pass, then continue.

1. `closedLidSessionContinuesWhenHelperDetailsArePermissionDenied`
   - Given helper status is running and process observation says inaccessible but existing.
   - When the app handles its next tick.
   - Then state remains running and the app writes an active heartbeat.
   - This is the complete 1.0.2 regression, beyond the value-level check at `Tests/main.swift:106-116`.

2. `closedLidStartWaitsForConfirmedSleepDisabled`
   - Given the power command returns and the power adapter reports the old value for a bounded delay.
   - When the helper starts.
   - Then status stays starting until confirmation, then becomes running.
   - If confirmation times out, the helper restores the setting and reports stopped or recovery required.
   - This preserves the 1.0.1 regression without rewriting production source.

3. `closedLidStopRestoresBeforeAppReturnsToIdle`
   - Start through the lifecycle interface, observe running, request stop, and let the helper consume the inactive lease.
   - Assert restoration confirmation precedes the app's idle transition and the lease is removed.
   - This covers the cross-process contract that neither current suite executes.

4. `ordinaryDisplayAssertionFailureReleasesSystemAssertion`
   - Given the system-sleep assertion succeeds and the display assertion fails.
   - Then the first assertion is released, state returns to idle, and the error is observable.
   - This checks cleanup at `Sources/App.swift:95-113` through the app interface.

5. `lidCloseRequestsDisplaySleepOncePerCloseTransition`
   - Feed open, closed, closed, open, closed snapshots.
   - Assert two display-sleep requests.
   - The current Python runner forces the lid open and discards this command.

6. `authorizationCancellationLeavesNoActiveSession`
   - Given administrator approval is cancelled.
   - Then state returns to idle, the lease is inactive or removed, no recovery is claimed, and a later start can proceed.

7. `launcherReturnsOnlyAfterRunningOrTerminalStatus`
   - Exercise the helper's `--launch` behavior with an isolated worker adapter.
   - Assert it never reports success while status is still starting and propagates terminal failure reasons.

8. `quitDuringClosedLidStopWaitsForRestorationOrUsesBoundedFallback`
   - Verify `applicationShouldTerminate` at `Sources/Menu.swift:204-220` through a controlled lifecycle state.
   - Assert normal confirmation replies once and timeout cleanup also replies once.

The first three protect the failures with the largest practical cost. The lid transition is next because README says physical lid-close verification remains pending.

## Prioritized changes and acceptance criteria

### Stage 1: compile unchanged product modules in tests

Create Xcode targets and move the existing checks into XCTest test cases. Preserve the Python cases until their replacements pass.

Acceptance criteria:

- No test reads Swift source text or calls `.replace` to create compilable fixtures.
- The safe test action compiles `KeepAwakeCore`, `KeepAwakeApp`, and helper lifecycle code from the same files used by the product.
- The safe plan runs without administrator approval and without a real `pmset` mutation.
- A deliberate change that removes activation confirmation makes the 1.0.1 regression fail.
- A deliberate change that maps permission denial to process exit makes the 1.0.2 lifecycle regression fail.

### Stage 2: deepen and type the session lifecycle

Move lifecycle transitions out of global SDK calls and independent optionals. Keep one UI facade and one helper loop.

Acceptance criteria:

- App state cannot represent running without active options and session context.
- Helper status uses a `Codable` enum while decoding existing 1.0.2 status strings.
- Start, stop, authorization cancellation, automatic policy stop, helper exit, and recovery each have a behavior test through the lifecycle interface.
- `AwakeModel` no longer creates process, power, timing, or status adapters inside lifecycle methods.

### Stage 3: replace three external-state dependencies with real seams

Add production and deterministic test adapters for power interaction and process observation. Add timing substitution while extracting the lifecycle.

Acceptance criteria:

- Tests can model delayed power application, denied process metadata, PID reuse, missing process, time advance, and lid transitions without source changes or sleeps.
- Production adapters have small smoke checks against read-only OS behavior where possible.
- Internal modules such as `SessionPolicy` are not mocked.

### Stage 4: clear Swift 6 concurrency diagnostics incrementally

Fix the authorization callback contract, then enable complete checking in the app target while retaining Swift 5 language mode.

Acceptance criteria:

- The current app source compiles with `-warn-concurrency -strict-concurrency=complete` without warnings.
- Tests that touch UI state are marked `@MainActor`.
- A Swift 6 language-mode trial build succeeds before the product changes language mode.

### Stage 5: add release test plans and one UI smoke test

Acceptance criteria:

- `Safe` is the default test plan and cannot invoke live power changes.
- `Privileged hardware` is opt-in and clearly labels real assertions, authorization, sleep-setting, and physical-lid checks.
- The UI smoke test opens the menu and verifies an ordinary start/stop state change with an isolated assertion adapter or a dedicated safe test build.

## Verification performed

No live assertion, root command, administrator prompt, or real `pmset` mutation ran.

- `./scripts/test.sh`: PASS, 23 checks, exit 0, 3.86 seconds.
- `python3 Tests/helper_integration.py`: PASS, 12 selected helper checks, exit 0, 22.28 seconds.
- App compile with Swift 5 complete concurrency checking: exit 0 with two diagnostics at `Sources/App.swift:179`.
- App compile with Swift 6 language mode: exit 1 with the same capture warning and one data-race error at line 179.
- Helper compile with Swift 6 language mode: exit 0 with no output.
- Toolchain: Xcode 26.6 build 17F113, Apple Swift 6.3.3.
- Worktree after checks: `main...origin/main`, no tracked or untracked changes shown. Generated `build/` content is ignored.

## Primary references

- Apple, Updating your existing codebase to accommodate unit tests: https://developer.apple.com/documentation/Xcode/updating-your-existing-codebase-to-accommodate-unit-tests
- Apple, Improving code assessment by organizing tests into test plans: https://developer.apple.com/documentation/xcode/organizing-tests-to-improve-feedback
- Apple, Asynchronous tests and expectations: https://developer.apple.com/documentation/xctest/asynchronous-tests-and-expectations
- Apple, Adding tests to your Xcode project: https://developer.apple.com/documentation/xcode/adding-tests-to-your-xcode-project
- Apple, Migrating a test from XCTest: https://developer.apple.com/documentation/Testing/MigratingFromXCTest
- Swift.org, Swift 6 migration strategy: https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/migrationstrategy/
- Swift Package Manager, PackageDescription test targets: https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html

## Limits

The repository's single squashed feature commit does not preserve the pre-1.0.1 or pre-1.0.2 source and test revisions, so the exact historical test gap cannot be reconstructed from Git. The supplied graph was stale for the reviewed files; direct reads cover every tracked source and test file, while excluded scripts were read separately. This assessment did not exercise the installed app, administrator authorization, real IOKit assertion, real `pmset`, or a physical lid close.
