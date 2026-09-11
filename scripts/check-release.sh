#!/bin/zsh -f
set -eu
cd "${0:A:h:h}"

app=${1:-"$PWD/build/Keep Awake.app"}
archive=${2:-}
image=${3:-}
extract_root=

cleanup() {
    [[ -z "$extract_root" ]] || /bin/rm -rf -- "$extract_root"
}
trap cleanup EXIT INT TERM

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

    extract_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/keepawake-release.XXXXXX")
    COPYFILE_DISABLE=1 /usr/bin/ditto -x -k "$archive" "$extract_root" || fail "ZIP extraction failed"
    extracted_app="$extract_root/Keep Awake.app"
    [[ -d "$extracted_app" && ! -L "$extracted_app" ]] || fail "ZIP does not contain a regular Keep Awake.app bundle"
    /usr/bin/codesign --verify --deep --strict "$extracted_app" || fail "ZIP app code signature verification failed"

    python3 - "$app" "$extract_root" <<'PY' || fail "ZIP app payload does not match the checked app bundle"
from pathlib import Path
import hashlib
import os
import stat
import sys


expected_app = Path(sys.argv[1])
extract_root = Path(sys.argv[2])
actual_app = extract_root / "Keep Awake.app"

if sorted(path.name for path in extract_root.iterdir()) != ["Keep Awake.app"]:
    raise SystemExit("ZIP contains content outside Keep Awake.app")


def inventory(root: Path) -> dict[str, tuple[object, ...]]:
    entries: dict[str, tuple[object, ...]] = {}
    pending = [root]
    while pending:
        directory = pending.pop()
        for entry in os.scandir(directory):
            path = Path(entry.path)
            relative = str(path.relative_to(root))
            metadata = entry.stat(follow_symlinks=False)
            mode = stat.S_IMODE(metadata.st_mode)
            if entry.is_symlink():
                entries[relative] = ("symlink", mode, os.readlink(path))
            elif entry.is_dir(follow_symlinks=False):
                entries[relative] = ("directory", mode)
                pending.append(path)
            elif entry.is_file(follow_symlinks=False):
                digest = hashlib.sha256()
                with path.open("rb") as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(block)
                entries[relative] = ("file", mode, digest.digest())
            else:
                entries[relative] = ("unsupported", mode)
    return entries


expected = inventory(expected_app)
actual = inventory(actual_app)
if expected != actual:
    missing = sorted(expected.keys() - actual.keys())
    extra = sorted(actual.keys() - expected.keys())
    changed = sorted(name for name in expected.keys() & actual.keys() if expected[name] != actual[name])
    print(f"missing={missing} extra={extra} changed={changed}", file=sys.stderr)
    raise SystemExit(1)
PY
fi

if [[ -n "$image" ]]; then
    [[ -s "$image" && ! -L "$image" ]] || fail "disk image is missing, empty, or is a symlink: $image"
    /usr/bin/hdiutil verify "$image" || fail "disk image verification failed"
fi

print "Artifact checks passed for version $app_version."
