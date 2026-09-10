#!/bin/zsh -f
set -eu
cd "${0:A:h:h}"
build="$PWD/build"
dist="$PWD/dist"
stage="$build/dmg"
[[ ! -L "$build" && ! -L "$dist" ]] || { print -u2 "Refusing to package through a symlinked build or dist directory."; exit 1; }
for target in "$stage" "$dist/Keep Awake.dmg" "$dist/Keep Awake.zip"; do
    [[ ! -L "$target" ]] || { print -u2 "Refusing to replace a symlinked package path: $target"; exit 1; }
done
./scripts/build.sh
/bin/rm -rf -- "$stage"
/bin/rm -f -- "$dist/Keep Awake.dmg" "$dist/Keep Awake.zip"
mkdir -p "$stage" "$dist"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr "$build/Keep Awake.app" "$stage/Keep Awake.app"
/bin/ln -s /Applications "$stage/Applications"
/bin/cp INSTALL.md "$stage/Read me.md"
COPYFILE_DISABLE=1 /usr/bin/hdiutil create -volname 'Keep Awake' -srcfolder "$stage" -format UDZO "$dist/Keep Awake.dmg"
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$build/Keep Awake.app" "$dist/Keep Awake.zip"
./scripts/check-release.sh "$build/Keep Awake.app" "$dist/Keep Awake.zip" "$dist/Keep Awake.dmg"
print 'Packages are in dist/'
