#!/bin/zsh -f
set -eu
cd "${0:A:h:h}"
./scripts/build.sh
mkdir -p build/dmg dist
/usr/bin/ditto 'build/Keep Awake.app' 'build/dmg/Keep Awake.app'
[[ -e build/dmg/Applications ]] || /bin/ln -s /Applications build/dmg/Applications
/bin/cp INSTALL.md 'build/dmg/Read me.md'
/usr/bin/hdiutil create -volname 'Keep Awake' -srcfolder build/dmg -ov -format UDZO 'dist/Keep Awake.dmg'
/usr/bin/ditto -c -k --keepParent 'build/Keep Awake.app' 'dist/Keep Awake.zip'
print 'Packages are in dist/'
