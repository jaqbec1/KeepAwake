# Keep Awake 1.1.0 candidate verification

Verified on 10 September 2026 on an Apple Silicon Mac running macOS 26.6.2, using Apple Swift 6.3.3 in Swift 5 language mode. The candidate is version 1.1.0, build 4, on `codex/reliability-pass`. The implementation follows the [reconnaissance plan](recon/2026-09-10/README.md).

## Automated results

The final `./scripts/test.sh` run passed all 59 checks after the controller and packaging simplifications and review follow-up:

- 27 shared policy, heartbeat, request, and process checks.
- 15 isolated helper integration scenarios.
- 16 production controller and application-adapter checks.
- One packaging regression that builds and packages a temporary checkout containing stale resources.

The default suite made no administrator request, login-item registration, live sleep assertion, or actual power-setting change. Helper integration tests compile temporary source copies with fake power services. Controller tests compile the production controller and adapter with injected external dependencies.

A separate mutation probe changed process-exit detection to the original `!isAlive` behavior in a temporary copy. The production-controller regression then failed because the closed-lid session did not reach running. This confirms that the new regression catches the permission-denial bug; it does not reproduce an actual privileged session.

The controller and adapter also compiled with `-strict-concurrency=complete -warnings-as-errors`, and all 16 controller checks passed against that executable. The full app build passed with complete concurrency checking enabled. `git diff --cached --check` passed.

## Candidate artifacts

`./scripts/package.sh` built the app, ZIP, and DMG. Bundle and ZIP content checks passed, including version agreement and absence of AppleDouble entries. Ad hoc signature verification passed. The extracted ZIP's executables and Info.plist match the built app. `hdiutil verify` confirmed the DMG checksum.

SHA-256 values for these local artifacts:

```text
623266e8cee97826af6bccb9d14a63600eb60ffb35bb4fe8b83ec7aa0de300fe  Keep Awake.dmg
2c286998cb83bd4af92faef064fb175ff5262e09db3720438345f11495f52714  Keep Awake.zip
```

A rebuild can produce different archive hashes. These values identify this candidate, not every build of version 1.1.0.

## Review and limits

An independent Astra review covered privileged ownership, heartbeat freshness, recovery locking, and controller failure paths. It found two controller regressions and a partial-launch failure gap, which were fixed and rechecked. Three Sol reviewers then covered reuse, quality, and efficiency. The parent removed unused Combine state copies and reused the packaging checker's required-file list. Independent packaging assertions and controller callback ordering were retained.

The completed [Compound Engineering review](reviews/2026-09-10-keep-awake-1.1.0-code-review.md) found no remaining source defect. Its two retained controller-testing gaps were closed in one follow-up batch. Four new cases exercise delayed authorization, terminal status during pending authorization, cancelled or failed recovery, and incomplete restoration after successful authorization. The full suite was rerun afterward and passed. No production code or packaged artifact changed in that follow-up.

The installed application remains 1.0.2. Native automation could inspect Finder but timed out when selecting the installed menu-bar app. The candidate was not installed or launched for UI acceptance.

Physical lid behavior, live activation and restoration, prolonged locked-screen operation, and crash/restart durability remain pending. Follow the [manual verification procedure](verification.md) on the exact candidate. In particular, the runtime ownership journal does not establish durable recovery after abrupt restart.

This Mac has no valid code-signing identity configured. The artifacts use local ad hoc signing and are not notarized public releases. No repository visibility change or public release was made.
