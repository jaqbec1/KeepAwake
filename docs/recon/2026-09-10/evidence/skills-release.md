# Keep Awake skill and public-release reconnaissance

Reviewed state: `main` at `dced7ae262e909ef19e8b248e553a8ec9e3ea86f`, app version `1.0.2`, on 10 September 2026.

This report is read-only reconnaissance. I did not install skills, alter global configuration, edit Keep Awake, publish a release, or change repository visibility. I assessed the upstream methods and applied selected review lenses. I did not claim that the full pstack or Compound Engineering orchestrators ran.

## Decision

Keep the GitHub repository private for now. It is safe to make it public only after the source-publication gates below pass. The app itself does not have to be open source to be distributed publicly. A notarized binary can be hosted somewhere else while the source stays private. GitHub Releases in a private repository are available only to people with read access, so public downloads would need a public repository or another host.

The current `1.0.2` files are a credible local build, not a public release. The main blockers are:

- No license. GitHub reports `licenseInfo: null`, and no `LICENSE` file is tracked. GitHub explains that without a license, default copyright applies and other people cannot reproduce, distribute, or create derivative works. A visible source repository would therefore not be open source.
- The checked ZIP is ad hoc signed. `codesign -dvvv` reports `Signature=adhoc` and no Team Identifier. `spctl -a -t exec` rejects the extracted app. Apple documents Developer ID signing and notarization as the normal direct-distribution path under Gatekeeper.
- There is no tag, GitHub Release, or Actions workflow. The GitHub API returned empty tag and release arrays and `total_count: 0` workflows.
- The install instructions point to ignored local files. [README.md](/Users/jmatyka/Projects/KeepAwake/README.md:9) tells readers to open `dist/Keep Awake.dmg`, but [.gitignore](/Users/jmatyka/Projects/KeepAwake/.gitignore:2) excludes `dist/`. A source checkout or GitHub source archive will not contain the advertised installer.
- Personal material is present in the current tree and Git history. [PRODUCT.md](/Users/jmatyka/Projects/KeepAwake/PRODUCT.md:13) names Jakub and his company-Mac constraint. [PRODUCT.md](/Users/jmatyka/Projects/KeepAwake/PRODUCT.md:17) and [README.md](/Users/jmatyka/Projects/KeepAwake/README.md:9) contain `/Users/jmatyka/...` paths. [Info.plist](/Users/jmatyka/Projects/KeepAwake/Resources/Info.plist:16) says `Built for Jakub Matyka. 2026.` All three commits record `jakub.matyka@wakacje.pl` as author and committer email. Editing the latest files will not remove the old blobs or commit metadata.
- Public hardware behavior is not fully proven. [README.md](/Users/jmatyka/Projects/KeepAwake/README.md:57) says the physical lid-close check and live Stop and restoration check are still pending. For an app whose privileged mode changes a global sleep setting, those are release gates.

## Repository and artifact evidence

The repository has only three commits. `faf0371` is empty, `d4eb92b` adds all 16 tracked files in one 1,382-line change, and `dced7ae` merges it to `main`. The branch has no later source changes. That makes a pre-public history rewrite manageable, but it is still a separate destructive operation and needs an explicit decision.

Version data currently agrees:

- [Info.plist](/Users/jmatyka/Projects/KeepAwake/Resources/Info.plist:9) has `CFBundleShortVersionString` `1.0.2`.
- [Info.plist](/Users/jmatyka/Projects/KeepAwake/Resources/Info.plist:10) has build number `3`.
- [Shared.swift](/Users/jmatyka/Projects/KeepAwake/Sources/Shared.swift:9) has `version = "1.0.2"`.

Nothing enforces that agreement against a future Git tag. Add a release check that fails unless tag, marketing version, app version, and build number follow the chosen policy.

The package scripts have a stale-state defect:

- [build.sh](/Users/jmatyka/Projects/KeepAwake/scripts/build.sh:4) creates build folders but never creates a clean app bundle. Removed resources can survive from an earlier build.
- [package.sh](/Users/jmatyka/Projects/KeepAwake/scripts/package.sh:5) reuses `build/dmg`. Removed files can survive into a later disk image.
- The current ZIP contains nine AppleDouble `._*` entries. They are packaging noise and show that the archive was not checked as a clean public artifact.

The test entry point is incomplete. [test.sh](/Users/jmatyka/Projects/KeepAwake/scripts/test.sh:5) compiles and runs only `Tests/main.swift`. The helper lifecycle suite is a separate command, `python3 Tests/helper_integration.py`, in [README.md](/Users/jmatyka/Projects/KeepAwake/README.md:20). A developer or CI job can run `./scripts/test.sh` successfully while skipping all twelve helper integration checks. Provide one safe test command that runs both suites and preserves the optional live assertion as an explicit hardware-local mode.

The current artifacts have SHA-256 values, but the project does not publish them or regenerate them in a controlled release job:

```text
2502c79a265b3b5473eb9c3d3ae4ed994cd80e79c2a6d165610881a3af81f062  Keep Awake.dmg
ed4a0b66ba216087bd3ffbe622f5e703506cbd4fcebadc655c4ada4a804bf6d9  Keep Awake.zip
```

The DMG checksum is internally valid. The extracted ZIP app passes `codesign --verify --deep --strict`, which only proves that its ad hoc seal is internally consistent. Gatekeeper still rejects it.

## Recommended capability shortlist

### 1. Proof against the real artifact

Use pstack's `principle-prove-it-works` as the release rule. It says to exercise the real feature path and retain a deterministic proof when possible. This fits Keep Awake exactly because compilation cannot prove an IOKit assertion, a root helper heartbeat, a lid transition, or restoration of `SleepDisabled`.

Acceptance criteria:

- A scripted nonprivileged check builds from a clean directory, runs policy and helper integration tests, verifies both nested and outer signatures, checks versions, scans the archive listing, and records hashes.
- One documented default test command runs both the Swift policy suite and `Tests/helper_integration.py`. Its exit status fails if either suite fails. The live IOKit assertion remains an explicit option because it changes live machine state briefly.
- A hardware checklist runs on the exact candidate artifact. It covers ordinary Start and Stop, charger removal, timer expiry, administrator-approved closed-lid activation, physical lid close, live Stop, helper crash recovery, and final `SleepDisabled 0`.
- CI and hardware results stay separate. A GitHub macOS runner cannot prove lid behavior or an interactive administrator prompt.

Source: [pstack principle-prove-it-works](https://github.com/cursor/plugins/blob/f8abeddd1862dc73704e3d719dd73df0d51b8c71/pstack/skills/principle-prove-it-works/SKILL.md)

### 2. Clean, repeatable build and packaging operations

Apply pstack's `principle-make-operations-idempotent` to `build.sh` and `package.sh`. Each invocation should start from explicit empty staging directories and converge on the same file set. Combine it with `principle-boundary-discipline`: validate release inputs such as version, signing identity, tag, output paths, and notarization credentials once at the script boundary.

Acceptance criteria:

- Two clean builds from the same commit produce the same expected bundle file list. If byte-for-byte reproducibility is not practical because signatures or disk images contain timestamps, document that limit and compare normalized contents.
- Deleting a resource from source and rebuilding cannot leave it in the app, ZIP, or DMG.
- The ZIP has no `._*`, `.DS_Store`, build cache, or local path content.
- Missing signing or notarization inputs fail before creating something named as a release artifact.

Sources: [make operations idempotent](https://github.com/cursor/plugins/blob/f8abeddd1862dc73704e3d719dd73df0d51b8c71/pstack/skills/principle-make-operations-idempotent/SKILL.md), [boundary discipline](https://github.com/cursor/plugins/blob/f8abeddd1862dc73704e3d719dd73df0d51b8c71/pstack/skills/principle-boundary-discipline/SKILL.md)

### 3. Behavior-first tests through the existing local Matt Pocock skill

Use the already installed `/Users/jmatyka/.agents/skills/tdd` for future fixes. Its central rule matches pstack's `principle-test-behavior-not-implementation`: call code through a user-facing or module-facing seam and assert a literal observable result. Keep Awake already has useful policy and isolated helper tests, so the next gain comes from filling release-critical behavior gaps, not increasing test count.

The local skill is an older, expanded variant. It is not byte-for-byte equal to Matt Pocock's current upstream `tdd` skill at commit `3cca18b`. Its core behavior-first and vertical-slice method is still aligned. Do not install pstack TDD beside it. That would create two triggers for the same discipline.

Acceptance criteria:

- Every regression test fails on the reproduced bug and passes after the fix.
- Tests assert session state, helper status, power state, or visible behavior. They do not stop at a method-call assertion.
- New privileged lifecycle behavior has at least one interruption or retry case.

Sources: [Matt Pocock TDD](https://github.com/mattpocock/skills/blob/3cca18b368ae95cdbdebbff572ccafa662551015/skills/engineering/tdd/SKILL.md), [pstack test behavior, not implementation](https://github.com/cursor/plugins/blob/f8abeddd1862dc73704e3d719dd73df0d51b8c71/pstack/skills/principle-test-behavior-not-implementation/SKILL.md)

### 4. Scoped release review with Compound Engineering

Use Compound Engineering's code-review method before a release candidate, with the scope pinned to the candidate tag or commit. For Keep Awake, the useful lenses are correctness, tests, shell packaging, documentation, and the product intent in `PRODUCT.md`. The full orchestrator was not run here. It carries cross-model routing and persona machinery that is larger than this reconnaissance and can conflict with the requested model policy.

Acceptance criteria:

- The review names an exact fixed point and exact candidate commit.
- Every finding cites a file and line or a runtime proof.
- The final review includes source, scripts, user documentation, the app bundle, and release metadata.
- Model routing follows the user's rule: normal work stays on the default model, and Astra is reserved for hard review or architecture questions. A skill's preset provider roster does not override that rule.

The CE work skill is useful later for implementing an approved release plan and preserving local verification evidence. `ce-commit-push-pr` becomes useful only after the user asks to publish a branch or PR. Neither skill grants permission to make the repository public or publish a release.

Local sources assessed: `ce-code-review`, `ce-work`, and `ce-commit-push-pr` from Compound Engineering `3.24.0`.

### 5. Blast-radius checks for privileged lifecycle changes

Use pstack's `blast-radius` method when a small change touches helper startup, heartbeat ownership, recovery, process identity, or `pmset`. Its useful question is the one fact the change is safe because of, followed by a runnable proof. This is better suited to Keep Awake than a broad generic architecture review.

Acceptance criteria:

- The review traces both activation and cleanup for the changed state.
- At least one runnable check proves the central safety fact.
- Any fact that cannot be run on CI is marked as hardware-tested or unproven.

Source: [pstack blast-radius](https://github.com/cursor/plugins/blob/f8abeddd1862dc73704e3d719dd73df0d51b8c71/pstack/skills/blast-radius/SKILL.md)

### 6. A small Keep Awake verification skill, after the harness is real

The idea in pstack's `create-verification-skill` is useful: give a cold agent exact launch, doctor, drive, evidence, and cleanup steps. Do not install or copy it wholesale now. Its upstream output is Cursor-specific and assumes a programmatic user-path harness. Keep Awake currently has scripts and manual checks, but no reliable control harness for its menu bar UI and administrator prompt.

Create a small project-local verification skill only after the release checks above have stable commands. It should describe the actual AppKit app and preserve manual hardware steps instead of pretending that a unit test drove the menu.

Acceptance criteria:

- A new agent can identify the exact candidate version, run all safe checks, launch only the process it owns, and clean up only that process.
- Evidence includes the action and resulting power state.
- The skill refuses concurrent closed-lid tests and requires a final normal-sleep check.

Source: [pstack create-verification-skill](https://github.com/cursor/plugins/blob/f8abeddd1862dc73704e3d719dd73df0d51b8c71/pstack/skills/create-verification-skill/SKILL.md)

## Methods that would be cargo cult here

- Do not install all of pstack. `architect` runs an arena with a preset multi-provider model roster and asks for multiple structural designs. There is no evidence that Keep Awake needs a rewrite, and the product deliberately uses AppKit and `NSMenu`. Preserve that choice.
- Do not run pstack `interrogate` as written. Its fixed heterogeneous reviewer roster conflicts with the user's model preference. A small number of risk-driven reviewers is enough, with Astra only on the hard privileged-lifecycle questions.
- Do not install the full Matt Pocock bundle. `tdd`, `improve-codebase-architecture`, and `grill-me` are already present locally. Current upstream adds useful skills such as `diagnosing-bugs` and `code-review`, but CE already provides the same broad capabilities. Add one only when a real task needs its distinct method.
- Do not run `improve-codebase-architecture` as release work. It is for recurring change friction and deepening modules. This repository has one feature commit, so it has no history that proves a hot spot. Packaging, notarization, and hardware proof have a clearer payoff.
- Do not use CE browser, React, web-performance, or iOS simulator skills. This is a native AppKit menu bar app built directly with `swiftc`. The iOS-focused Xcode simulator workflow does not verify it.
- Do not download a Swift or SwiftUI skill because it is popular. No reviewed upstream skill supplied a stronger release method than Apple's own signing and notarization documentation plus this repository's tests. Revisit that only when a concrete Swift problem appears.

Upstream provenance:

- pstack was assessed at Cursor plugins commit [`f8abeddd`](https://github.com/cursor/plugins/commit/f8abeddd1862dc73704e3d719dd73df0d51b8c71), dated 9 September 2026. Its plugin license is MIT.
- Matt Pocock's skills were assessed at commit [`3cca18b`](https://github.com/mattpocock/skills/commit/3cca18b368ae95cdbdebbff572ccafa662551015), dated 4 September 2026. The repository license is MIT.

## Public-source gates

1. Decide whether the source should be open source. If yes, choose a license and add a plain `LICENSE` file. If no, keep the repository private and distribute notarized binaries elsewhere.
2. Decide which identity should be public. Replace personal-machine paths and the private product brief. Use a standard copyright string. If the employer email and old personal text must not be public, rewrite all three commits before changing visibility. A `.mailmap` only changes display in some tools and does not erase raw commit metadata.
3. Rewrite install documentation around a versioned download URL. Keep source-build instructions separate from end-user installation.
4. Add contributor and support expectations only if outside contributions are wanted. A small project does not need a large governance template.

GitHub license source: [Licensing a repository](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)

## Binary release gates

1. Build in empty staging directories and remove AppleDouble files from deliverables.
2. Sign the helper and app with the intended Developer ID Application identity. Enable the hardened runtime and verify the nested code and outer app before packaging.
3. Submit the app, ZIP, or DMG with `notarytool`, inspect the notary log, and staple the ticket where Apple supports it.
4. Test the downloaded artifact under quarantine on a separate clean Apple-silicon Mac or clean user environment. `spctl` must accept it, the app must launch without bypass instructions, and the exact hardware checklist must pass.
5. Tag the exact commit as `v1.0.2` only if this artifact remains the first public candidate. Otherwise bump the version. Create a GitHub Release or publish to the chosen host, attach DMG and ZIP only if both are supported, and publish SHA-256 checksums and concise release notes.
6. Run safe tests on every pull request with a macOS CI job. Keep Developer ID and notarization credentials in protected release secrets, restrict signing to version tags, and avoid exposing credentials to pull requests.

Apple sources: [Signing Mac software with Developer ID](https://developer.apple.com/developer-id/), [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Upload a macOS app to be notarized](https://help.apple.com/xcode/mac/current/en.lproj/dev88332a81e.html)

GitHub release source: [About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)

## Suggested order

1. Finish the physical lid-close and restoration checks on the installed `1.0.2` candidate.
2. Decide public source versus public binary only.
3. If public source, settle license and identity, then sanitize current files and history before changing visibility.
4. Make build and package scripts start clean, add the release checks, and remove archive noise.
5. Add Developer ID signing, hardened runtime, notarization, and a clean-machine acceptance run.
6. Pin the candidate commit, run a scoped CE-style review, tag it, generate artifacts in the release job, and publish hashes with the release.

Changing visibility should be the last action. It is not required to complete any of the preparation above.
