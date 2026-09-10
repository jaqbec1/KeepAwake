#!/bin/zsh -f
set -eu
cd "${0:A:h:h}"
build="$PWD/build"
app="$build/Keep Awake.app"
[[ ! -L "$build" ]] || { print -u2 "Refusing to use a symlinked build directory: $build"; exit 1; }
[[ ! -L "$app" ]] || { print -u2 "Refusing to replace a symlinked app bundle: $app"; exit 1; }
mkdir -p "$build/module-cache"
/bin/rm -rf -- "$app" "$build/AppIcon.iconset"
/bin/rm -f -- "$build/make-icon"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
sdk=$(/usr/bin/xcrun --show-sdk-path)
common=(-swift-version 5 -strict-concurrency=complete -warn-concurrency -O -sdk "$sdk" -target arm64-apple-macos14.0 -module-cache-path "$build/module-cache")
/usr/bin/xcrun swiftc "${common[@]}" Sources/Shared.swift Sources/Helper.swift -o "$app/Contents/Resources/KeepAwakeHelper"
/usr/bin/xcrun swiftc "${common[@]}" Sources/Shared.swift Sources/SessionController.swift Sources/App.swift Sources/Menu.swift -o "$app/Contents/MacOS/KeepAwake" -framework AppKit -framework ServiceManagement -framework IOKit
/bin/cp Resources/Info.plist "$app/Contents/Info.plist"
/bin/cp Resources/Help.html "$app/Contents/Resources/Help.html"
/usr/bin/xcrun swiftc "${common[@]}" scripts/Icon.swift -o "$build/make-icon" -framework AppKit
"$build/make-icon" "$build/AppIcon.iconset"
/usr/bin/iconutil -c icns "$build/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - --identifier sh.holistic.keepawake.helper "$app/Contents/Resources/KeepAwakeHelper"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
print "Built $app"
