#!/bin/zsh -f
set -eu
cd "${0:A:h:h}"
test_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/keepawake-tests.XXXXXX")
trap '/bin/rm -rf -- "$test_root"' EXIT INT TERM
mkdir -p "$test_root/module-cache"
common=(-swift-version 5 -module-cache-path "$test_root/module-cache")

/usr/bin/xcrun swiftc "${common[@]}" Sources/Shared.swift Tests/main.swift -o "$test_root/KeepAwakeTests" -framework IOKit
"$test_root/KeepAwakeTests" "$@"

python3 Tests/helper_integration.py

/usr/bin/xcrun swiftc "${common[@]}" Sources/Shared.swift Sources/SessionController.swift Sources/App.swift Tests/SessionControllerTests.swift -o "$test_root/SessionControllerTests" -framework AppKit -framework ServiceManagement -framework IOKit
"$test_root/SessionControllerTests"

python3 Tests/packaging_test.py
