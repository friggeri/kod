#!/bin/sh
# Dry fixture for Scripts/release/thin-macho-arm64.sh.
# Creates local arm64, x86_64, and universal Mach-O stand-ins plus a
# nested Sparkle-like tree. No signing credentials or publishing.
#
# Usage: Scripts/release/test-thin-macho-arm64.sh

set -eu
set -o pipefail

export LC_ALL=C

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
thin_script="$repository_root/Scripts/release/thin-macho-arm64.sh"
workdir="$repository_root/Artifacts/release-thin-tests/run-$$"

cleanup() {
    rm -rf -- "$workdir"
}
trap cleanup EXIT HUP INT TERM

if [ ! -x "$thin_script" ] && [ ! -f "$thin_script" ]; then
    printf '%s\n' "FAIL: missing $thin_script" >&2
    exit 1
fi
if ! command -v clang >/dev/null 2>&1; then
    printf '%s\n' "FAIL: clang is required to build architecture fixtures." >&2
    exit 1
fi

rm -rf -- "$workdir"
mkdir -p "$workdir/src"

cat > "$workdir/src/main.c" <<'EOF'
int main(void) { return 0; }
EOF

clang -arch arm64 -o "$workdir/arm64.bin" "$workdir/src/main.c"
clang -arch x86_64 -o "$workdir/x86_64.bin" "$workdir/src/main.c"
lipo -create "$workdir/arm64.bin" "$workdir/x86_64.bin" -output "$workdir/universal.bin"
printf 'resource-body\n' > "$workdir/note.txt"
resource_digest=$(shasum -a 256 "$workdir/note.txt" | awk '{print $1}')

fail() {
    printf '%s\n' "FAIL: $1" >&2
    exit 1
}

pass() {
    printf '%s\n' "ok: $1"
}

require_arch() {
    actual=$(lipo -archs "$1")
    if [ "$actual" != "$2" ]; then
        fail "expected '$2' in $1, found '$actual'"
    fi
}

# Universal input is thinned to arm64-only.
cp "$workdir/universal.bin" "$workdir/universal-copy.bin"
chmod 755 "$workdir/universal-copy.bin"
if ! "$thin_script" "$workdir/universal-copy.bin"; then
    fail "universal Mach-O should thin successfully"
fi
require_arch "$workdir/universal-copy.bin" "arm64"
if [ ! -x "$workdir/universal-copy.bin" ]; then
    fail "thinned binary lost its executable bit"
fi
pass "universal Mach-O thins to arm64"

# Already-arm64 input is accepted and left arm64-only.
cp "$workdir/arm64.bin" "$workdir/already-arm64.bin"
if ! "$thin_script" "$workdir/already-arm64.bin"; then
    fail "arm64-only Mach-O should be accepted"
fi
require_arch "$workdir/already-arm64.bin" "arm64"
pass "arm64-only Mach-O is accepted"

# Invalid x86_64-only input fails closed.
if "$thin_script" "$workdir/x86_64.bin" >/dev/null 2>&1; then
    fail "x86_64-only Mach-O must fail"
fi
require_arch "$workdir/x86_64.bin" "x86_64"
pass "x86_64-only Mach-O fails closed"

# Missing path fails closed.
if "$thin_script" "$workdir/does-not-exist" >/dev/null 2>&1; then
    fail "missing path must fail"
fi
pass "missing path fails closed"

# Non-Mach-O single-file input fails closed and is not rewritten.
if "$thin_script" "$workdir/note.txt" >/dev/null 2>&1; then
    fail "non-Mach-O file must fail"
fi
if [ "$(shasum -a 256 "$workdir/note.txt" | awk '{print $1}')" != "$resource_digest" ]; then
    fail "non-Mach-O file was modified"
fi
pass "non-Mach-O file fails closed and is untouched"

# Directory with only resources fails closed.
mkdir -p "$workdir/empty-tree/Resources"
cp "$workdir/note.txt" "$workdir/empty-tree/Resources/Info.plist"
if "$thin_script" "$workdir/empty-tree" >/dev/null 2>&1; then
    fail "directory without Mach-O files must fail"
fi
pass "directory without Mach-O files fails closed"

# Nested Sparkle-like tree: every helper thins; resources stay put.
sparkle_root="$workdir/Sparkle.framework"
version_dir="$sparkle_root/Versions/B"
mkdir -p \
    "$version_dir/Updater.app/Contents/MacOS" \
    "$version_dir/XPCServices/Downloader.xpc/Contents/MacOS" \
    "$version_dir/XPCServices/Installer.xpc/Contents/MacOS" \
    "$version_dir/Resources"
cp "$workdir/universal.bin" "$version_dir/Sparkle"
cp "$workdir/universal.bin" "$version_dir/Autoupdate"
cp "$workdir/universal.bin" "$version_dir/Updater.app/Contents/MacOS/Updater"
cp "$workdir/universal.bin" "$version_dir/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
cp "$workdir/universal.bin" "$version_dir/XPCServices/Installer.xpc/Contents/MacOS/Installer"
cp "$workdir/arm64.bin" "$version_dir/already-arm64-helper"
printf 'sparkle-resource\n' > "$version_dir/Resources/Info.plist"
chmod 755 \
    "$version_dir/Sparkle" \
    "$version_dir/Autoupdate" \
    "$version_dir/Updater.app/Contents/MacOS/Updater" \
    "$version_dir/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "$version_dir/XPCServices/Installer.xpc/Contents/MacOS/Installer"
plist_digest=$(shasum -a 256 "$version_dir/Resources/Info.plist" | awk '{print $1}')

if ! "$thin_script" "$sparkle_root"; then
    fail "Sparkle-like tree should thin successfully"
fi

for helper in \
    "$version_dir/Sparkle" \
    "$version_dir/Autoupdate" \
    "$version_dir/Updater.app/Contents/MacOS/Updater" \
    "$version_dir/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "$version_dir/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
    "$version_dir/already-arm64-helper"
do
    require_arch "$helper" "arm64"
    if [ ! -x "$helper" ]; then
        fail "helper lost executable bit: $helper"
    fi
done
if [ "$(shasum -a 256 "$version_dir/Resources/Info.plist" | awk '{print $1}')" != "$plist_digest" ]; then
    fail "Sparkle resource was modified"
fi
pass "nested Sparkle helpers thin; resources untouched"

# A Sparkle-like tree missing arm64 in one nested helper fails closed.
bad_root="$workdir/Sparkle-missing-arm64.framework"
mkdir -p "$bad_root/Versions/B/XPCServices/Installer.xpc/Contents/MacOS"
cp "$workdir/universal.bin" "$bad_root/Versions/B/Sparkle"
cp "$workdir/x86_64.bin" "$bad_root/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
if "$thin_script" "$bad_root" >/dev/null 2>&1; then
    fail "nested helper without arm64 must fail"
fi
require_arch "$bad_root/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" "x86_64"
pass "nested helper without arm64 fails closed"

printf '%s\n' "==> thin-macho-arm64 fixture tests passed"
