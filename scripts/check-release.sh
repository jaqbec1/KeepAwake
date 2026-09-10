#!/bin/zsh -f
set -eu
cd "${0:A:h:h}"

app=${1:-"$PWD/build/Keep Awake.app"}
archive=${2:-}
image=${3:-}

fail() {
    print -u2 "Artifact check failed: $1"
    exit 1
}

[[ -d "$app" && ! -L "$app" ]] || fail "app bundle is missing or is a symlink: $app"
required_entries=(
    'Contents/Info.plist'
    'Contents/MacOS/KeepAwake'
    'Contents/Resources/AppIcon.icns'
    'Contents/Resources/Help.html'
    'Contents/Resources/KeepAwakeHelper'
)
for entry in "${required_entries[@]}"; do
    [[ -f "$app/$entry" ]] || fail "missing bundle file: $entry"
done
[[ -x "$app/Contents/MacOS/KeepAwake" ]] || fail "main executable is not executable"
[[ -x "$app/Contents/Resources/KeepAwakeHelper" ]] || fail "helper is not executable"

source_version=$(/usr/bin/sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' Sources/Shared.swift | /usr/bin/head -1)
plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
plist_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)
app_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
[[ -n "$source_version" && "$source_version" == "$plist_version" && "$plist_version" == "$app_version" ]] || \
    fail "version mismatch: source=$source_version plist=$plist_version app=$app_version"
[[ "$plist_build" == <-> && "$plist_build" -gt 0 && "$plist_build" == "$app_build" ]] || \
    fail "invalid or mismatched build number: plist=$plist_build app=$app_build"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist") == "sh.holistic.keepawake" ]] || \
    fail "unexpected bundle identifier"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist") == "KeepAwake" ]] || \
    fail "unexpected bundle executable"
/usr/bin/codesign --verify --deep --strict "$app" || fail "code signature verification failed"

if [[ -n "$archive" ]]; then
    [[ -f "$archive" && ! -L "$archive" ]] || fail "ZIP archive is missing or is a symlink: $archive"
    listing=$(/usr/bin/unzip -Z1 "$archive")
    print -r -- "$listing" | /usr/bin/grep -Eq '(^|/)\._|(^|/)\.DS_Store($|/)' && fail "ZIP contains AppleDouble or .DS_Store files"
    for entry in "${required_entries[@]}"; do
        print -r -- "$listing" | /usr/bin/grep -Fxq "Keep Awake.app/$entry" || fail "ZIP is missing: Keep Awake.app/$entry"
    done
fi

if [[ -n "$image" ]]; then
    [[ -s "$image" && ! -L "$image" ]] || fail "disk image is missing, empty, or is a symlink: $image"
fi

print "Artifact checks passed for version $app_version."
