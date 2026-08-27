#!/bin/sh
# Produces Kod's complete, signed, notarized v0.1.x release artifact set.
# This is a production-only pipeline: every credential and gate is required,
# and any failure aborts before a draft GitHub Release can be created.
#
# Usage: Scripts/release/package-release.sh <version>

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

"$release_scripts_dir/preflight.sh" "$version"

rm -rf -- "$output_dir"
mkdir -p "$output_dir/archive"

printf '%s\n' "==> [1/5] Promoting and signing tested Apple Silicon archive"
"$release_scripts_dir/build-archive.sh" "$output_dir/archive" "$version"
app_path="$output_dir/archive/Kod.xcarchive/Products/Applications/Kod.app"

printf '%s\n' "==> [2/5] Verifying app lifecycle metadata"
python3 "$release_scripts_dir/verify-install-lifecycle.py" "$app_path"

printf '%s\n' "==> [3/5] Notarizing and stapling app"
"$release_scripts_dir/codesign-and-notarize.sh" "$app_path"
"$release_scripts_dir/verify-gatekeeper.sh" "$app_path"

printf '%s\n' "==> [4/5] Packaging DMG and Sparkle ZIP"
"$release_scripts_dir/make-dmg.sh" "$app_path" "$output_dir" "$version"
dmg_path="$output_dir/Kod-$version-arm64.dmg"
zip_path="$output_dir/Kod-$version-arm64.zip"

printf '%s\n' "==> [5/5] Notarizing and stapling DMG"
"$release_scripts_dir/codesign-and-notarize.sh" "$dmg_path"
"$release_scripts_dir/verify-gatekeeper.sh" "$dmg_path"

for required in \
    "Kod-$version-arm64.dmg" \
    "Kod-$version-arm64.zip" \
    "Kod-$version-licenses.zip" \
    install-lifecycle-report.json
do
    if [ ! -f "$output_dir/$required" ]; then
        printf '%s\n' "BLOCKED: missing required release artifact: $required" >&2
        exit 65
    fi
done

printf '%s\n' "==> Signed release binaries are ready in $output_dir"
