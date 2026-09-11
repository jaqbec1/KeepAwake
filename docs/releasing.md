# Preparing a Keep Awake release

## Development candidates

Run `./scripts/test.sh`, then `./scripts/package.sh`. Packaging validates bundle metadata and signatures, ZIP payload integrity, and the DMG checksum. CI retains the tested ZIP and DMG for 14 days, named with the source commit. These artifacts are development candidates; a passing CI run does not certify them for public stable distribution.

The current build script always signs ad hoc. It does not contact Apple, upload credentials, or publish releases. The existing v1.1.0 prerelease and installed Homebrew version stay unchanged by these preparation checks.

## Developer ID release, once membership is available

This procedure is prepared, but the signing and notarization path has not been exercised. Apple documents the supported process in [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

1. Configure a Developer ID Application identity in the maintainer's Keychain. Keep its private key and notarization credentials outside the repository. Use a `notarytool` Keychain profile instead of putting passwords in scripts or shell history.
2. Finish the [manual acceptance checks](verification.md) and record the source commit and outcomes in a copy of the [acceptance record](release-acceptance-template.md). A restart that loses the ownership journal while retaining the sleep override requires a design fix, not a successful checkbox.
3. Choose a new version and build number. Update the source version, Info.plist, and changelog together. Do not overwrite previously published versioned artifacts.
4. Build in an isolated release checkout. Sign the helper first and the outer app second with the Developer ID identity, hardened runtime, and secure timestamps. Verify both signatures. Avoid adding entitlement exceptions without demonstrated need.
5. Archive the signed app and submit it with `xcrun notarytool submit --keychain-profile PROFILE --wait ARCHIVE`. Inspect the returned status and log; upload completion alone is not acceptance.
6. Staple and validate the accepted app ticket. Recreate the distribution ZIP from that stapled app, then construct and sign the DMG containing the same app. Submit the DMG for notarization, staple it, and validate its ticket.
7. Do not run the current `scripts/package.sh` after manual signing: it rebuilds and replaces the signed app with an ad hoc build. A future signing-aware packaging implementation must preserve the signed and stapled bundle and receive its own end-to-end test with real credentials.
8. Run the read-only release check against the final artifacts:

   ```sh
   ./scripts/check-public-release.sh \
     '/path/to/Keep Awake.app' \
     '/path/to/Keep Awake.zip' \
     '/path/to/Keep Awake.dmg'
   ```

9. Download the exact proposed artifacts onto a clean supported Mac and verify installation, Gatekeeper, UI, and helper activation/restoration. Re-run the relevant physical checks with hardened runtime enabled. Do not remove quarantine or disable Gatekeeper to make a check pass.
10. Publish only the verified artifacts, record their SHA-256 values, and update `Casks/keep-awake.rb` to the corresponding immutable version and ZIP checksum. Verify the actual downloaded cask with `brew audit --cask --new` before requesting official Homebrew inclusion.

`check-public-release.sh` validates package integrity, Gatekeeper acceptance of the ZIP-extracted app, and stapled tickets on that extracted app and the DMG. It does not prove the application's behavior, release stability, repository age, adoption, or acceptance by Homebrew maintainers. It is expected to reject today's ad hoc candidate.
