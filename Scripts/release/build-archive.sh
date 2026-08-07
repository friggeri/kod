#!/bin/sh
# Builds a Release .xcarchive for the given architecture (default:
# arm64, matching SPEC "Architecture priority: Apple silicon first").
# This never signs, notarizes, or packages — see codesign-and-notarize.sh
# and make-dmg.sh for those steps, kept separate so each stage's outcome
# (and any credential/hardware gate) is independently inspectable.
#
# Usage: Scripts/release/build-archive.sh [arm64|x86_64] [output-dir]

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
architecture=${1:-arm64}
output_dir=${2:-"$repository_root/Artifacts/release/$architecture"}

case "$architecture" in
    arm64|x86_64) ;;
    *)
        printf '%s\n' "Usage: $0 [arm64|x86_64] [output-dir]" >&2
        exit 64
        ;;
esac

mkdir -p "$output_dir"
archive_path="$output_dir/Kod.xcarchive"

printf '%s\n' "==> Archiving Kod (Release, $architecture) to $archive_path"
xcodebuild \
    -project "$repository_root/Kod.xcodeproj" \
    -scheme Kod \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$archive_path" \
    ARCHS="$architecture" \
    ONLY_ACTIVE_ARCH=NO \
    clean archive

printf '%s\n' "==> Archive complete: $archive_path"
printf '%s\n' "==> App bundle: $archive_path/Products/Applications/Kod.app"
