#!/bin/sh
# Reproducible vendoring script for the bundled, pinned ripgrep-compatible
# search engine used by SearchCore. This script is NOT part of the Xcode
# build; it is a record of how the binaries under
# Packages/KodCore/Sources/SearchCore/Resources/ripgrep/<target-triple>/rg
# were produced, and can be re-run to refresh them against the same pinned
# commit (see manifest.json) or to bump the pin after review.
#
# What it does, in order:
#   1. Downloads the ripgrep source tarball at the exact pinned commit from
#      GitHub and verifies its SHA-256 against manifest.json.
#   2. Builds the `rg` binary from that vendored source for Apple silicon
#      (aarch64-apple-darwin) with Cargo's default (non-PCRE2) feature set,
#      so the result has no
#      dependency on a system libpcre2.
#   3. Strips debug symbols, applies an ad-hoc development signature so macOS
#      can execute package tests, and copies the binary into SearchCore.
#      Production release signing replaces it with the Developer ID identity
#      inside-out before the app itself is signed.
#   4. Copies the upstream license texts into Vendor/Licenses.
#
# Requirements: curl, python3, and an Apple Silicon Rust toolchain
# (cargo/rustc) with the aarch64-apple-darwin target installed.

set -eu
set -o pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
work_dir="$script_dir/.work"
manifest="$script_dir/manifest.json"

resources_dir="$repository_root/Packages/KodCore/Sources/SearchCore/Resources/ripgrep"
licenses_dir="$repository_root/Vendor/Licenses"

tarball_url=$(python3 -c "import json; print(json.load(open('$manifest'))['ripgrep']['sourceTarballURL'])")
expected_sha256=$(python3 -c "import json; print(json.load(open('$manifest'))['ripgrep']['sourceTarballSHA256'])")

rm -rf "$work_dir"
mkdir -p "$work_dir"
trap 'rm -rf "$work_dir"' EXIT

printf '%s\n' "==> Downloading $tarball_url"
curl -sL "$tarball_url" -o "$work_dir/ripgrep-src.tar.gz"

actual_sha256=$(shasum -a 256 "$work_dir/ripgrep-src.tar.gz" | awk '{print $1}')
if [ "$actual_sha256" != "$expected_sha256" ]; then
    printf 'Checksum mismatch for ripgrep source tarball.\n' >&2
    printf 'Expected: %s\n' "$expected_sha256" >&2
    printf 'Actual:   %s\n' "$actual_sha256" >&2
    exit 1
fi

printf '%s\n' "==> Extracting"
mkdir -p "$work_dir/src"
tar -xzf "$work_dir/ripgrep-src.tar.gz" -C "$work_dir/src" --strip-components=1

for target in aarch64-apple-darwin; do
    printf '%s\n' "==> Building rg for $target"
    (
        cd "$work_dir/src"
        cargo build --release --locked --target "$target" --bin rg
    )

    mkdir -p "$resources_dir/$target"
    built_binary="$work_dir/src/target/$target/release/rg"
    vendored_binary="$resources_dir/$target/rg"
    cp "$built_binary" "$vendored_binary"
    chmod 755 "$vendored_binary"
    strip -S -x "$vendored_binary"
    codesign --force --sign - "$vendored_binary"
    printf '%s  %s\n' "$(shasum -a 256 "$vendored_binary" | awk '{print $1}')" "$target/rg"
done

printf '%s\n' "==> Copying license texts"
mkdir -p "$licenses_dir"
cp "$work_dir/src/LICENSE-MIT" "$licenses_dir/ripgrep-LICENSE-MIT.txt"
cp "$work_dir/src/UNLICENSE" "$licenses_dir/ripgrep-UNLICENSE.txt"
cp "$work_dir/src/COPYING" "$licenses_dir/ripgrep-COPYING.txt"

printf '%s\n' "Done. Review the diff, update manifest.json's targets if paths changed,"
printf '%s\n' "and record the new binary checksums in THIRD_PARTY_NOTICES.md."
