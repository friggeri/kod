#!/bin/sh
# Packages a signed and stapled Apple Silicon Kod.app as the direct-download
# DMG and Sparkle update ZIP, including project and third-party licenses.
#
# Usage: Scripts/release/make-dmg.sh <Kod.app> <output-dir> <version>

set -eu
set -o pipefail

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
app_path=${1:-}
output_dir=${2:-}
version=${3:-}

if [ -z "$app_path" ] || [ ! -d "$app_path" ] || [ -z "$output_dir" ] || [ -z "$version" ]; then
    printf '%s\n' "Usage: $0 <Kod.app> <output-dir> <version>" >&2
    exit 64
fi

architectures=$(lipo -archs "$app_path/Contents/MacOS/Kod")
if [ "$architectures" != "arm64" ]; then
    printf '%s\n' "BLOCKED: expected an arm64-only app, found: $architectures" >&2
    exit 65
fi
codesign --verify --deep --strict --verbose=2 "$app_path"
xcrun stapler validate "$app_path"

mkdir -p "$output_dir"
staging_dir="$output_dir/staging-arm64"
rm -rf -- "$staging_dir"
mkdir -p "$staging_dir/THIRD_PARTY_LICENSES"

cp -R "$app_path" "$staging_dir/Kod.app"
cp "$repository_root/LICENSE" "$staging_dir/LICENSE"
cp "$repository_root/THIRD_PARTY_NOTICES.md" "$staging_dir/THIRD_PARTY_NOTICES.md"
python3 "$repository_root/Scripts/release/collect-licenses.py" \
    "$staging_dir/THIRD_PARTY_LICENSES"
ln -s /Applications "$staging_dir/Applications"

zip_path="$output_dir/Kod-$version-arm64.zip"
dmg_path="$output_dir/Kod-$version-arm64.dmg"
license_archive="$output_dir/Kod-$version-licenses.zip"
rm -f "$zip_path" "$dmg_path" "$license_archive"

printf '%s\n' "==> Creating Sparkle update archive: $zip_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "$app_path" "$zip_path"
zip_roots=$(zipinfo -1 "$zip_path" | awk -F/ '{print $1}' | sort -u)
if [ "$zip_roots" != "Kod.app" ]; then
    printf '%s\n' "BLOCKED: Sparkle ZIP must contain only Kod.app, found: $zip_roots" >&2
    exit 65
fi

printf '%s\n' "==> Creating license archive: $license_archive"
(cd "$staging_dir" && /usr/bin/zip -qry \
    "../$(basename "$license_archive")" \
    "LICENSE" "THIRD_PARTY_NOTICES.md" "THIRD_PARTY_LICENSES")

printf '%s\n' "==> Creating direct-download image: $dmg_path"
hdiutil create \
    -volname "Kod $version" \
    -srcfolder "$staging_dir" \
    -ov \
    -format UDZO \
    "$dmg_path"

rm -rf -- "$staging_dir"
printf '%s\n' "==> Packaged: $zip_path"
printf '%s\n' "==> Packaged: $dmg_path"
printf '%s\n' "==> Packaged: $license_archive"
