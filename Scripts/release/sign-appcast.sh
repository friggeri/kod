#!/bin/sh
# Generates and verifies the signed Sparkle appcast after packaging completes.
#
# Usage: Scripts/release/sign-appcast.sh <version>

set -eu
set -o pipefail

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
release_scripts_dir="$repository_root/Scripts/release"
version=${1:-}
output_dir="$repository_root/Artifacts/release"

if [ -z "$version" ]; then
    printf '%s\n' "Usage: $0 <version>" >&2
    exit 64
fi
if [ -z "${SPARKLE_PRIVATE_KEY:-}" ]; then
    printf '%s\n' "BLOCKED: SPARKLE_PRIVATE_KEY is required to sign the appcast." >&2
    exit 78
fi
if [ -z "${KOD_SPARKLE_GENERATE_APPCAST:-}" ] \
    || [ ! -x "$KOD_SPARKLE_GENERATE_APPCAST" ]; then
    printf '%s\n' "BLOCKED: KOD_SPARKLE_GENERATE_APPCAST must name Sparkle 2.9.6's executable tool." >&2
    exit 78
fi

app_path="$output_dir/archive/Kod.xcarchive/Products/Applications/Kod.app"
zip_path="$output_dir/Kod-$version-arm64.zip"
appcast_path="$output_dir/appcast.xml"
if [ ! -d "$app_path" ] || [ ! -f "$zip_path" ]; then
    printf '%s\n' "BLOCKED: packaged app or Sparkle ZIP is missing." >&2
    exit 65
fi

appcast_input="$output_dir/.appcast-input-$$"
trap 'rm -rf -- "$appcast_input"; unset SPARKLE_PRIVATE_KEY' EXIT HUP INT TERM
umask 077
mkdir "$appcast_input"
cp "$zip_path" "$appcast_input/$(basename "$zip_path")"
rm -f "$appcast_path"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$KOD_SPARKLE_GENERATE_APPCAST" \
    --ed-key-file - \
    --download-url-prefix \
        "https://github.com/friggeri/kod/releases/download/v$version/" \
    --link "https://kod.dev/" \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    -o "$appcast_path" \
    "$appcast_input"

xmllint --noout "$appcast_path"
"$release_scripts_dir/verify-sparkle-release.sh" \
    "$app_path" \
    "$zip_path" \
    "$appcast_path" \
    "$version"
