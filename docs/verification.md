# Verifying a Keep Awake build

Run safe automated checks before testing the installed application. A passing automated suite cannot prove physical lid behavior or an administrator prompt.

## Automated checks

From the project directory:

```sh
./scripts/test.sh
./scripts/package.sh
```

The default suite must not request administrator approval, register login items, create live sleep assertions, or change power settings. It covers policy and lease validation, isolated helper processes, the production session controller with controlled external dependencies, and packaging regressions.

The separate `./scripts/test.sh --live-assertion` option briefly creates and releases an ordinary IOKit assertion on the current Mac. It does not test the closed-lid override.

## Native interaction

Stop any existing session, wait for restoration, and quit before replacing the app. Record the version shown in About Keep Awake and the tested commit.

Check these paths on the candidate app:

- Open and dismiss the cup menu by mouse and keyboard. Confirm focus returns to the previous application.
- Start and stop an ordinary session. Check the filled cup, countdown, action label, and last outcome.
- Choose a custom duration. Reject blank input, fractions, zero, and values above 1,440. Accept 1 and 1,440.
- Cancel administrator authorization. The menu should explain the cancellation and permit a later start.
- Open Session details after cancellation or an error. Confirm the full explanation is readable.
- Copy diagnostics. Confirm it contains versions and session options without paths, account identifiers, or raw authorization errors.
- Use VoiceOver to find Start, Stop, state, outcome, duration, and recovery. Check both appearance modes, increased contrast, and an auto-hidden menu bar.
- Check menu placement and focus on each connected display, including different scaling factors.
- Reopen from Finder. Enable and disable launch at login once, restoring the original preference. A login launch must remain idle.

## Closed-lid operation

Do not run competing utilities that change the same sleep override. Save work before a test that may end a session. Use a ventilated desk.

1. Record the initial sleep override with a read-only `pmset -g` inspection. If sleep is already disabled, establish ownership before continuing.
2. Start a short closed-lid session and approve the administrator prompt yourself.
3. Observe successful activation, close the lid, then reopen it. Use a harmless timestamp-writing job to establish whether work continued while closed.
4. Choose Stop. Wait for restoration confirmation and independently verify that the override is off.
5. Repeat for timer expiry, charger removal with charger-only enabled, and Quit.
6. Run at least 30 minutes with the display locked and, separately, the lid closed. Record heartbeat intervals and whether the helper remained active. An initial 30-minute pass does not establish indefinite reliability.

Do not deliberately overheat or deeply discharge the laptop to test safeguards. Automated adapters cover those policy inputs.

## Crash and restart recovery

Use a disposable test environment for uncatchable helper termination and abrupt restarts. A helper killed this way cannot run its own cleanup or thermal and battery checks.

Record both the power setting and ownership journal before and after each case:

- Unexpected app exit with a live helper.
- Helper termination by a normal signal.
- Uncatchable helper termination, followed by an explicit recovery attempt.
- Orderly restart and abrupt restart while the override is enabled.
- Recovery while another legitimate helper owns the lock. It must refuse to change that session's setting.

Never infer restoration just from a missing process, an idle menu, or a reboot. Confirm the actual setting. If the override survives while its ownership journal disappears, stop release testing and address durable recovery ownership before making a reliability claim.

## Distribution

For a public release, use a checkout outside cloud-synced folders so macOS can sign the generated bundle without Finder metadata from the sync provider. Use a Developer ID Application certificate and a `notarytool` keychain profile for the same Apple Developer team. Keep signing credentials outside the repository and outside untrusted pull-request jobs.

```sh
KEEP_AWAKE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
KEEP_AWAKE_NOTARY_PROFILE='keep-awake-notary' \
./scripts/package.sh --release
```

Publish the ZIP and DMG from `dist/release/` after the script verifies their notarization tickets and Gatekeeper accepts them. Use the ZIP's SHA-256 in the Homebrew cask and point the cask at the new release tag. Test a fresh quarantined download on a clean Mac before announcing the release. The regular development command, `./scripts/package.sh`, produces ad hoc packages in `dist/`.

Record observed outcomes separately from this checklist. Mark unperformed checks as pending, not passed.
