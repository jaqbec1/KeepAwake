#!/bin/zsh -f
set -eu
cd "${0:A:h:h}"
build="$PWD/build"
dist="$PWD/dist"
stage="$build/dmg"
release_dir=
if [[ "${1:-}" == --release && $# == 1 ]]; then
    : "${KEEP_AWAKE_SIGN_IDENTITY:?Set this to the Developer ID Application certificate name.}"
    : "${KEEP_AWAKE_NOTARY_PROFILE:?Set this to a notarytool keychain profile.}"
    export KEEP_AWAKE_SIGN_IDENTITY
    release_dir="$dist/release"
    [[ ! -e "$release_dir" && ! -L "$release_dir" ]] || {
        print -u2 "Move the previous release packages aside before reusing $release_dir."
        exit 1
    }
elif (( $# != 0 )); then
    print -u2 'Usage: ./scripts/package.sh [--release]'
    exit 1
fi
[[ ! -L "$build" && ! -L "$dist" ]] || { print -u2 "Refusing to package through a symlinked build or dist directory."; exit 1; }
for target in "$stage" "$dist/Keep Awake.dmg" "$dist/Keep Awake.zip"; do
    [[ ! -L "$target" ]] || { print -u2 "Refusing to replace a symlinked package path: $target"; exit 1; }
done
./scripts/build.sh
/bin/rm -rf -- "$stage"
mkdir -p "$stage" "$dist"
app="$build/Keep Awake.app"
package_dir="$dist"
if [[ -n "$release_dir" ]]; then
    temporary=$(/usr/bin/mktemp -d "$dist/.release.XXXXXXXX")
    trap '/bin/rm -rf -- "$temporary"' EXIT
    package_dir="$temporary/packages"
    mkdir "$package_dir"
    submission="$temporary/Keep Awake.zip"
    /usr/bin/ditto -c -k --keepParent "$app" "$submission"
    /usr/bin/xcrun notarytool submit "$submission" --keychain-profile "$KEEP_AWAKE_NOTARY_PROFILE" --wait --timeout 20m
    /usr/bin/xcrun stapler staple "$app"
else
    /bin/rm -f -- "$dist/Keep Awake.dmg" "$dist/Keep Awake.zip"
fi
zip="$package_dir/Keep Awake.zip"
dmg="$package_dir/Keep Awake.dmg"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr "$app" "$stage/Keep Awake.app"
/bin/ln -s /Applications "$stage/Applications"
/bin/cp INSTALL.md "$stage/Read me.md"
COPYFILE_DISABLE=1 /usr/bin/hdiutil create -volname 'Keep Awake' -srcfolder "$stage" -format UDZO "$dmg"
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$app" "$zip"
./scripts/check-release.sh "$app" "$zip" "$dmg"

if [[ -n "$release_dir" ]]; then
    /usr/bin/codesign --sign "$KEEP_AWAKE_SIGN_IDENTITY" --timestamp --identifier sh.holistic.keepawake.dmg "$dmg"
    /usr/bin/xcrun notarytool submit "$dmg" --keychain-profile "$KEEP_AWAKE_NOTARY_PROFILE" --wait --timeout 20m
    /usr/bin/xcrun stapler staple "$dmg"
    /usr/bin/xcrun stapler validate "$dmg"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
    /usr/bin/ditto -x -k "$zip" "$temporary/unzipped"
    extracted_app="$temporary/unzipped/Keep Awake.app"
    /usr/bin/xcrun stapler validate "$extracted_app"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$extracted_app"
    /bin/mv "$package_dir" "$release_dir"
    print "Release packages are in $release_dir"
else
    print 'Packages are in dist/'
fi
