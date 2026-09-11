#!/bin/zsh -f
set -eu
cd "${0:A:h:h}"

if [[ $# -ne 3 ]]; then
    print -u2 'Usage: scripts/check-public-release.sh APP ZIP DMG'
    exit 2
fi

./scripts/check-release.sh "$1" "$2" "$3"

extracted_root=$(mktemp -d "${TMPDIR:-/tmp}/keepawake-public-check.XXXXXX")
trap 'rm -rf "$extracted_root"' EXIT
/usr/bin/ditto -x -k "$2" "$extracted_root"
extracted_app="$extracted_root/Keep Awake.app"

if ! /usr/sbin/spctl --assess --type execute --verbose=4 "$extracted_app"; then
    print -u2 'Public release check failed: Gatekeeper rejected the app.'
    exit 1
fi
if ! /usr/bin/xcrun stapler validate "$extracted_app"; then
    print -u2 'Public release check failed: the app has no valid stapled notarization ticket.'
    exit 1
fi
if ! /usr/bin/xcrun stapler validate "$3"; then
    print -u2 'Public release check failed: the DMG has no valid stapled notarization ticket.'
    exit 1
fi

print 'Public binary checks passed. Hardware acceptance and Homebrew eligibility require separate evidence.'
