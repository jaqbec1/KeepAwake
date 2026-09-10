# Keep Awake improvement reconnaissance

Reviewed 10 September 2026, version 1.0.2, commit `dced7ae262e909ef19e8b248e553a8ec9e3ea86f`.

Keep the native AppKit menu. The next investment should make sessions dependable, failures understandable, and the actual application lifecycle testable. A SwiftUI rewrite or more preferences would not solve the problems found here.

The app is a useful personal utility, but its closed-lid mode has not yet earned a public reliability claim. The user confirmed sustained countdown operation after the 1.0.2 fix. Physical lid-close behavior, live Stop and restoration, extended background operation, and restart recovery still need evidence from the exact release candidate.

## What this review did

Three independent reviewers covered architecture and tests, privileged lifecycle, and skills and distribution. The two general reviews used GPT-5.6 Sol. The privileged lifecycle review used GPT-6 Astra because root-process ownership and recovery were the difficult part. The parent reviewed native macOS interaction and reconciled the findings.

We assessed the installed Matt Pocock-derived TDD and architecture skills, Compound Engineering review methods, Impeccable's relevant product guidance, and upstream pstack. We applied selected methods. We did not run the complete CE or pstack orchestrators or install their full bundles.

The graph snapshot had changed file metadata, so material findings use direct reads of current source. Safe tests and isolated probes ran. No real power settings, running sessions, installed application, Git history, or repository visibility changed. This report and its evidence are the only new project files.

## Findings and confidence

| Finding | Evidence | Priority |
| --- | --- | --- |
| A clock correction can end a healthy closed-lid session | The unchanged lease reader accepts the current timestamp and rejects the same heartbeat at +21 or -6 seconds. It uses wall-clock age. | Fix in the next reliability pass. |
| Recovery can be hidden when a dead helper's PID is reused by an inaccessible root process | An isolated probe reproduces the conditional state. Natural PID reuse was not reproduced. | Fix with a root-lock-arbitrated recovery attempt. Preserve the existing permission-denial fix. |
| Session completion reasons are hidden in a tooltip | `App.swift:206-214` stores the reason; `Menu.swift:136-137` displays generic status and puts the reason only in the tooltip. | Show the last outcome directly in the menu. |
| Tests omit the app lifecycle and modify helper source before compilation | The Swift suite compiles Shared.swift only. The Python suite rewrites Shared.swift and Helper.swift and invokes `--run`, not the app or launcher. | Add tests through a production session-controller interface. |
| Swift 6 language mode fails at the authorization callback | Trial compile fails at `App.swift:179`; Swift 5 complete concurrency checking reports diagnostics there. The current Swift 5 build remains supported. | Narrow callback isolation fix, then enable strict checking. |
| Packaging can retain removed resources | Build and DMG scripts reuse staging directories. The ZIP also contains nine AppleDouble entries. | Clean staging and validate artifact contents. |
| The distributed ZIP is not ready for normal Gatekeeper installation | Its ad hoc signature verifies internally, but `spctl` rejects the extracted app. | Developer ID signing, notarization, and downloaded-artifact testing before public binary release. |

Three additional concerns need deliberate verification or a product decision:

- App Nap can throttle timers. Closed-lid mode relies on the GUI's one-second heartbeat without a retained activity assertion in that process. This is a credible failure mechanism, not a reproduced long-running failure. Use an appropriate scoped activity and measure heartbeat gaps under a locked screen and closed lid. [Apple App Nap guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html).
- Apple source persists the `disablesleep` setting, while the ownership journal lives under `/private/var/run`. Current macOS reboot cleanup and abrupt-restart behavior were not tested. Establish whether an override can outlive its recovery evidence before promising restart safety. [Apple power-management source](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m#L790).
- An uncatchable helper termination bypasses restoration and the helper's battery and thermal checks. Manual recovery is the current design. Decide whether that is sufficient for unattended closed-lid jobs. Signing alone also does not remove the trust placed in a helper launched from a user-writable application bundle.

Do not turn these uncertainties into claims of demonstrated data loss or a proven exploit. Equally, successful activation is insufficient evidence of recovery or hours of unattended operation.

## Recommended implementation order

### 1. Make the previous failure testable

Extract the smallest session-controller boundary needed to drive start, helper status, heartbeat, stop, and recovery with deterministic dependencies. Keep `AwakeModel` as the main-actor UI adapter and keep the helper's lifecycle together. Inject time, power behavior, and process observations where tests need control. Avoid a dependency framework or a protocol for every Foundation call.

The first test must reproduce the complete failure fixed by 1.0.2: a running root helper with inaccessible process details leaves the app running and writing fresh active heartbeats. Follow with delayed activation confirmation and Stop waiting for confirmed restoration. Compile the same production implementation in tests. Preserve the existing Python scenarios until equivalent coverage replaces them.

Acceptance:

- Mapping permission denial to process exit makes the regression fail.
- Removing activation confirmation makes the delayed-power regression fail.
- Stop cannot report ordinary idle success before restoration is confirmed.
- One safe test command runs both existing suites and the new lifecycle tests without administrator approval or global power changes.

### 2. Fix heartbeat and recovery behavior

Replace wall-clock lease expiry with boot-scoped monotonic freshness or sequence observation measured by the helper. Preserve session identity and file validation. Permit recovery when process observation is inconclusive, with the privileged helper's lock making the final decision. A real active helper must remain protected.

Retain an appropriate activity while a closed-lid session starts, runs, and restores settings. Release it after completion. Keep display sleep available. Show the latest outcome in the menu and add a small Copy diagnostics action with versions, state, and relevant errors.

Acceptance:

- Simulated clock jumps do not stop a healthy heartbeat; an actually stale heartbeat still ends the session.
- An inaccessible reused PID cannot permanently hide recovery, and recovery cannot overwrite an active helper's session.
- Authorization cancellation, expiry, power-policy stop, and helper loss all produce a visible reason.
- The narrow authorization callback fix passes complete concurrency checking before a Swift language-mode change.

### 3. Prove cleanup on real hardware

Use a documented, separately invoked hardware procedure against the exact candidate app. Record initial and final settings and do not run concurrent closed-lid tests.

Cover ordinary start and stop, administrator cancellation, closed-lid activation, physical lid close, reopening and Stop, timer expiry, charger removal, a locked screen, and at least 30 minutes of background operation. Measure heartbeat freshness and confirm normal sleep restoration after every case. The 30-minute run is an initial acceptance check, not proof of indefinite reliability.

Use disposable hardware or a suitable isolated environment for helper SIGKILL and restart experiments. Establish ownership-journal and setting behavior across orderly and abrupt restart. If the setting can survive its journal, implement durable root-owned recovery data with boot identity. Decide from this evidence whether a supervised privileged service is necessary. Do not introduce one merely because it is a common macOS pattern.

Acceptance is the observed machine behavior and restored setting, not just a countdown, process, or kernel flag during activation.

### 4. Improve native interaction and build maintenance

Preserve NSMenu, standard checkmarks, SF Symbols, and platform alerts. Verify keyboard navigation, VoiceOver, focus restoration, multiple displays, menu-bar auto-hide, Finder reopening, and Stop accessibility. Explore `NSStatusItem.menu` against the current manually positioned menu only if interaction testing supports the change. Apple provides it as the direct menu association. [NSStatusItem.menu](https://developer.apple.com/documentation/appkit/nsstatusitem/menu).

A conventional Xcode project is a reasonable next build structure for the app, helper, resources, signing, and test targets. It is not a prerequisite for the first regression or an urgent rewrite. Introduce only targets that have real build or test responsibilities. A core Swift package is optional if command-line testing provides a concrete benefit. Maintain one authoritative source and build graph.

Use typed lifecycle states and a Codable helper-state enum as those paths change. Decode the existing journal strings so an upgrade does not strand recovery information.

### 5. Prepare a public release

Start builds and packages in clean staging. Add a macOS CI gate for safe tests, compilation, versions, bundle contents, and signatures. Keep hardware results separate from CI. Sign release artifacts with Developer ID, enable the appropriate hardened runtime configuration, notarize, and test a quarantined download on a clean environment. [Apple distribution guidance](https://developer.apple.com/developer-id/), [Apple notarization guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Before public source publication, choose a license and public identity. Current files contain personal-machine details, and all three commits contain the employer email. A later cleanup commit does not remove history. Settle any history rewrite separately before changing visibility. Replace local `dist/` installation instructions with an actual versioned download, then publish the exact tested artifact and hashes.

Public source and public binary distribution are separate choices. Reliability and packaging work can proceed while the repository stays private.

## Which skills are useful here

| Method | Concrete use |
| --- | --- |
| Matt Pocock TDD | One failing behavior regression at a time through unchanged production interfaces. |
| Matt Pocock architecture principles | Concentrate session transitions behind a small interface; preserve already useful policy and helper modules. |
| Compound Engineering code review | Review a pinned candidate with correctness, lifecycle, tests, shell packaging, and product requirements in scope. |
| pstack prove-it-works | Require evidence from the actual app and hardware where unit tests cannot prove behavior. |
| pstack idempotence and boundary discipline | Clean staging, validated release inputs, and repeatable package contents. |
| pstack blast-radius | Trace activation and restoration together for every privileged lifecycle change. |
| Impeccable product guidance | Familiar macOS controls and visible outcomes. Its mobile-specific audit rules do not establish macOS quality. |

Upstream references are pinned in the [skills and release evidence](evidence/skills-release.md): [Matt Pocock TDD](https://github.com/mattpocock/skills/blob/3cca18b368ae95cdbdebbff572ccafa662551015/skills/engineering/tdd/SKILL.md) and [pstack prove-it-works](https://github.com/cursor/plugins/blob/f8abeddd1862dc73704e3d719dd73df0d51b8c71/pstack/skills/principle-prove-it-works/SKILL.md).

Do not install overlapping TDD skills, adopt preset multi-provider reviewer rosters, or apply React, browser, or iOS simulator workflows to this AppKit app. Create a small project verification skill only after its commands and hardware procedure exist. Normal implementation and routine review can use Sol; reserve Astra for unresolved privilege, crash-recovery, or concurrency design questions.

## Follow-up design sources

The user also suggested [Impeccable](https://impeccable.style/) and [Jhey Tompkins](https://www.jhey.dev/). Checked both on 10 September 2026.

Impeccable is already installed locally as version 3.9.1 and was part of this review. Its current [command documentation](https://impeccable.style/docs/) supports a focused follow-up:

| Method | Keep Awake application |
| --- | --- |
| clarify | Explain why a session stopped and what recovery does. |
| distill | Keep Start/Stop prominent and infrequent preferences subordinate. |
| harden | Review cancellation, long labels, missing status, and recovery failures. |
| onboard | Explain ordinary versus closed-lid operation before the first privileged session. |
| polish | Check menu grouping, labels, icon states, and platform consistency. |

These are recommendations for the implementation phase, not completed UI passes. Native macOS controls remain the design system. Browser overlays and CSS rules cannot verify AppKit interaction, and system-provided materials should not be removed to satisfy a generic web style prohibition.

Jhey's supplied site presents web UI demos and interaction experiments. It is useful as a source of interaction ideas, particularly for a future product website. It does not itself identify an installable agent skill package. No package should be inferred from the word "skills" in a designer's biography. Any borrowed idea needs a specific benefit for this small utility, platform-appropriate implementation, and low idle energy cost.

The follow-up reviewer traced the site's GitHub link to Jhey's account and found [Figment](https://github.com/jh3y/figment/tree/c1e5dee8f5a08f4b8373385f404d80f857b51342). It contains seven SKILL.md files for a creative image-generation workflow. This is a real skill-bearing project, but its early-alpha workflow depends on Node, pnpm, and paid Krea generation. It may be useful for separately scoped icon or marketing artwork. It does not supply Swift/AppKit or privileged-helper expertise, so adding it is not recommended for the current implementation plan. No additional skills were installed.

## Verification and detailed evidence

- Safe Swift checks: 23 passed.
- Isolated helper checks: 12 passed.
- Swift 5 complete concurrency trial: compiled with diagnostics at App.swift:179.
- Swift 6 app trial: failed at that callback; helper trial compiled.
- Isolated clock and inaccessible-process probes reproduced the conditional findings above.
- A suspected helper run-loop spin did not reproduce.
- Background NSAppleScript use is not itself a defect. Apple DTS confirms the historic main-thread restriction was lifted; serialized use is supported. [Apple DTS clarification](https://developer.apple.com/forums/thread/759287).
- No new physical lid, administrator-prompt, live Stop, or restart test ran during this review.

Supporting reports contain source locations, commands, qualifications, and primary references:

- [Privileged lifecycle](evidence/security.md)
- [Architecture and tests](evidence/architecture-tests.md)
- [Skills, packaging, and publication](evidence/skills-release.md)
- [Native macOS interaction](evidence/ux.md)

The staged plan above is the final recommendation. The architecture report's larger target layout is a possible destination, not a requirement to create every target before fixing a bug.
