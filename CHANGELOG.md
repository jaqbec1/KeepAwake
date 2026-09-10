# Changelog

## 1.1.0

- Use boot-scoped monotonic heartbeat freshness so clock corrections do not interrupt closed-lid sessions.
- Keep explicit recovery available when macOS cannot inspect a process that reused an old helper PID. An active helper's lock still blocks recovery.
- Run session behavior through a testable production controller and keep the app active while it coordinates sleep prevention and restoration.
- Show session outcomes directly in the native menu, with full details and diagnostics copying.
- Build packages from clean staging directories and check their versions, signatures, and contents.
- Run safe policy, helper, controller, and packaging checks from one command, including in macOS CI.

This is a local ad hoc signed candidate. Physical lid-close, extended background operation, restart recovery, and public-distribution checks remain separate acceptance gates. See [the verification checklist](docs/verification.md).

## 1.0.2

Keep a closed-lid session running when macOS denies the ordinary app access to the root helper's process metadata.

## 1.0.1

Wait for macOS to apply a sleep-setting change before reporting activation or restoration.

## 1.0.0

Initial native menu bar app with ordinary and closed-lid sessions, duration choices, charger and battery controls, and manual recovery.
