# Keep Awake

A native macOS menu bar app for ordinary keep-awake and closed-lid sessions. Built for Apple silicon Macs on macOS 14 or later, without an App Store dependency.

The menu uses AppKit's standard background, typography, selection, separators, checkmarks, and submenus. Click the cup to start or stop a session, choose a duration, or change battery and display options.

## Install

Build the installer with `./scripts/package.sh`, then open `dist/Keep Awake.dmg` and drag the app to Applications. The ZIP contains the same app. Generated installers are not included in a source checkout. Stop any session and quit the existing app before replacing it.

This is an ad-hoc signed local build. It is not Developer ID signed or notarized for public distribution. No credentials or signing identities are included in the project.

## Build and check

Requires Xcode's macOS SDK and Swift compiler. No package downloads are needed.

```sh
./scripts/build.sh
./scripts/test.sh
./scripts/package.sh
```

The default test command runs the safe suites without administrator approval or changes to global sleep settings. Use `./scripts/test.sh --live-assertion` only when you also want the check that briefly creates and releases an ordinary idle-sleep assertion. The helper integration tests still compile a temporary fixture with fake power services. Session-controller tests compile the unchanged production controller and app adapter; they supply isolated external dependencies.

## Session behavior

- Start with a preset duration, a custom 1–1,440 minute timer, or Until stopped.
- Ordinary sessions use IOKit assertions. Closing the app releases them.
- Closed-lid sessions use `pmset disablesleep`. macOS asks for administrator approval for each session.
- Only while plugged in ends the session when the charger is disconnected.
- Battery sessions stop at the selected cutoff. All sessions stop if macOS reports serious or critical thermal pressure, or the power source cannot be read.
- Closed-lid mode puts the display to sleep on the lid-close transition.
- Launch at login starts the app idle. No session resumes automatically.
- Screen-lock settings remain unchanged. The app does not simulate keyboard or mouse activity.
- The menu shows the last session outcome. Session details displays the full explanation. Copy diagnostics includes app and macOS versions, state, and selected options, excluding raw authorization errors and file paths.

## Privileged helper

The main application runs as the user. For a closed-lid session, macOS authorizes the bundled helper for that session. It is not installed as a launch daemon and adds no passwordless sudo rule.

The helper takes an exclusive lock in a root-owned runtime directory and refuses to start if the global sleep override is already enabled. It journals ownership before making the change. After each power-setting command, it waits up to three seconds for the kernel to confirm the requested state. A heartbeat file is checked for its owner, session UUID, boot identity, monotonic age, regular-file type, link count, and size. Symlinks are rejected. Clock corrections do not change heartbeat freshness.

The helper verifies the app's process ID, owner, and creation time. The app treats denied access to the root helper's process metadata as unknown, and only infers an exit from a missing process or a confirmed identity mismatch. It also reads the helper's session status. It restores normal sleep when the app exits, the heartbeat expires after 20 seconds, the timer ends, the charger disconnects, the battery reaches its cutoff, or the helper receives a normal termination signal. Stop requests are normally picked up within one second.

A crash or force-kill of the privileged helper itself cannot run cleanup. On reopening, the app offers Restore normal sleep for its own interrupted session. The root-owned journal limits recovery to a session this app recorded. A global setting cannot arbitrate with another keep-awake utility; do not run multiple apps that change it simultaneously.

The runtime journal is `/private/var/run/sh.holistic.keepawake/session.json`. Session heartbeat files are in the user's temporary directory. Preferences use the `sh.holistic.keepawake` defaults domain. The sleep override can persist; restart behavior and journal survival still need hardware verification. Restarting alone is not proof that normal sleep has been restored.

## Verification

The 1.1.0 candidate passes 59 safe automated checks, strict controller concurrency compilation, and local artifact verification. It has not replaced the installed 1.0.2 app. See the [candidate results](docs/verification-1.1.0.md) and [manual verification procedure](docs/verification.md) for exact coverage and pending checks.

On 9 September 2026, 24 policy, heartbeat, process identity, root-process visibility, and live assertion checks passed. Twelve helper integration checks also passed, covering stop requests, app crashes, stale heartbeats, termination signals, timer expiry, charger loss, low battery, partial activation failure, delayed activation and restoration, and missing confirmation in either direction.

Version 1.0.1 fixes a premature activation check in 1.0.0. The previous helper read the kernel state once, immediately after `pmset` returned. A test with delayed power-service updates reproduced the failure before the fix and passed afterward. Activation, cleanup, and recovery now wait for confirmation; the launcher allows time for those bounded waits.

Version 1.0.2 fixes immediate session termination after successful activation. macOS denied the ordinary app access to the root helper's BSD process details. The app incorrectly treated this as an exit and removed the heartbeat on its next timer tick. A read-only check against an existing root process reproduced this error before the fix. The regression tests also check that an actual process exit still permits recovery.

The installed app's ordinary Start and Stop controls were exercised, and `pmset -g assertions` confirmed the app's assertion. The charger-only guard was also checked on battery. Closed-lid activation was tested with administrator approval in version 1.0.2. The helper stayed running beyond 30 seconds, macOS reported `SleepDisabled 1`, and the heartbeat continued updating. A physical lid-close check and live Stop/restoration check are still pending.

## Files

- `Sources/Menu.swift`: native menu, custom-duration dialog, app lifecycle.
- `Sources/App.swift`: preferences, menu-facing model, and macOS service adapters.
- `Sources/SessionController.swift`: testable session lifecycle, heartbeat, stop, and recovery coordination.
- `Sources/Shared.swift`: power readings, session policy, process identity, request and journal types.
- `Sources/Helper.swift`: privileged session lifecycle, cleanup, recovery.
- `Resources/Help.html`: bundled user guide.
- `Tests/`: policy and isolated helper integration checks.

## Remove

Stop the session, turn off Launch at login, quit the app, and move it to the Trash. If recovery is shown, restore normal sleep before removing the app. The bundled user guide has the manual recovery command.
