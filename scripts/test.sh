#!/bin/zsh -f
set -eu
cd "${0:A:h:h}"
mkdir -p build/module-cache
/usr/bin/xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" Sources/Shared.swift Tests/main.swift -o build/KeepAwakeTests -framework IOKit
build/KeepAwakeTests "$@"
