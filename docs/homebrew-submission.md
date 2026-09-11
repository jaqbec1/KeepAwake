# Official Homebrew submission

Checked 11 September 2026. Status: blocked before submission. The existing custom tap remains usable; inclusion in `Homebrew/homebrew-cask` is a separate maintainer decision.

## Required audit result

Command:

```sh
HOMEBREW_NO_AUTO_UPDATE=1 brew audit --cask --new jaqbec1/keepawake/keep-awake
```

The audit exited with status 1 and reported three failures:

1. Signature verification failed because the downloaded software does not meet Gatekeeper's distributor-signing requirements.
2. `v1.1.0` is a GitHub prerelease.
3. The upstream repository is below the audit's public-interest thresholds of 30 forks, 30 watchers, or 75 stars.

The downloaded ZIP has SHA-256 `2c286998cb83bd4af92faef064fb175ff5262e09db3720438345f11495f52714`. The installed bundle also failed `spctl --assess --type execute --verbose=4`. `security find-identity -v -p codesigning` found zero valid identities on this Mac. A valid ad hoc signature and successful local installation do not establish Gatekeeper acceptance.

## Additional acceptance requirements

The current [package acceptance policy](https://docs.brew.sh/Package-Acceptance-Policy) has stricter normal thresholds for an owner submitting their own project: 90 forks, 90 watchers, or 225 stars. A code repository under 30 days old is normally ineligible. The generic local audit above does not establish compliance with these additional owner-submission requirements.

GitHub currently reports zero stars, forks, and subscribers. The repository was created at `2026-09-09T23:36:03Z`. Its 30-day anniversary is `2026-10-09T23:36:03Z`, or 10 October in Warsaw. Reaching that date alone will not satisfy the adoption requirement. Maintainer exceptions exist, but no independently verified adoption evidence was established in this check. Do not manufacture interest or use a different submitter to disguise authorship.

The [cask requirements](https://docs.brew.sh/Acceptable-Casks) require Gatekeeper acceptance. They describe release-channel handling; the installed Homebrew audit currently rejects this specific prerelease. Do not simply remove the prerelease label to make the audit green. First complete the pending product acceptance work and publish the build intended for general users.

## Work needed before opening the PR

Preparation completed on 11 September: artifact validation now compares the extracted ZIP with the built app and verifies the DMG checksum, with regression cases for changed ZIP content, a different validly re-signed app, and a corrupt DMG. The full safe suite passes. CI is configured to retain checked candidate archives for 14 days. A separate [public-release check and signing procedure](releasing.md) and [hardware acceptance record](release-acceptance-template.md) are available. The public check rejects the current ad hoc candidate; the notarized success path and physical acceptance remain pending.

- Obtain or configure the developer's signing identity. Produce a Developer ID signed, notarized release and verify the downloaded artifact through Gatekeeper. Do not disable Gatekeeper or rely on removing quarantine.
- Complete physical lid-close, live restoration, extended background, and restart acceptance for the release candidate using [the verification procedure](verification.md).
- Publish the tested release, then update the cask's version and checksum to the exact new artifact. Preserve the existing release assets instead of silently replacing their bytes.
- Establish eligibility under the public-interest and repository-age policy, or document a real applicable exception.
- Refresh the upstream PR template and check for duplicate or previously refused submissions. An exact closed-PR search for `jaqbec1/KeepAwake` returned no results on this date; that is not an exhaustive name-conflict search.
- Prepare `Casks/k/keep-awake.rb` in a branch of a fork of `Homebrew/homebrew-cask`, following its then-current layout and token rules.
- Run style, the new-cask online audit, and installation/uninstallation checks against that submission checkout. Keep the user's normal installed app out of disposable uninstall tests.
- Have the user review the proposed cask and PR text before requesting Homebrew maintainer review.

## PR draft

Title, after the appropriate release is ready:

```text
keep-awake <version> (new cask)
```

Body draft:

> Adds Keep Awake, a native menu bar utility for preventing sleep on Apple silicon Macs. Upstream is https://github.com/jaqbec1/KeepAwake. This is a submission by the upstream repository owner.
>
> The cask uses the upstream release ZIP and pins its SHA-256. It requires macOS 14 or later and arm64. Closed-lid sessions request administrator approval individually; the app does not install a persistent privileged service.
>
> Before submission, attach the exact release URL, checksum, Gatekeeper result, passing audit/style output, install/uninstall results, and eligibility evidence here. These are not yet complete.
>
> AI disclosure: OpenAI Codex assisted with the app, cask, submission preparation, and draft text. The initial app review also used GPT-5.6 Sol and GPT-6 Astra agents. Human review of this proposed submission is still pending.

Do not copy this draft into an upstream PR while its placeholders and failed checks remain. Use the current upstream checkbox template and mark only actions actually performed.

Homebrew's [contribution rules](https://docs.brew.sh/How-To-Open-a-Homebrew-Pull-Request#artificial-intelligencelarge-language-model-aillm-usage) require disclosure of AI assistance and human review before submission. The contributor must personally answer maintainer questions and review comments without AI assistance. The user must handle that correspondence.

No upstream fork, branch, issue, or PR was created by this eligibility check. The published release, installed app, and custom cask were not modified.
