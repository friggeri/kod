#!/bin/sh
# Packages a built Kod.app into a distributable DMG and ZIP, alongside
# THIRD_PARTY_NOTICES.md and complete third-party license texts (SPEC 17 M4:
# "release documentation").
#
# Usage: Scripts/release/make-dmg.sh <path-to-Kod.app> <output-dir> [version]

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
app_path=${1:-}
output_dir=${2:-}
version=${3:-$(date +%Y.%m.%d)}

if [ -z "$app_path" ] || [ ! -d "$app_path" ] || [ -z "$output_dir" ]; then
    printf '%s\n' "Usage: $0 <path-to-Kod.app> <output-dir> [version]" >&2
    exit 64
fi

architecture=$(/usr/bin/file "$app_path/Contents/MacOS/Kod" | sed -n 's/.*Mach-O 64-bit executable \([a-z0-9_]*\).*/\1/p')
architecture=${architecture:-unknown}

mkdir -p "$output_dir"
staging_dir="$output_dir/staging-$architecture"
rm -rf "$staging_dir"
mkdir -p "$staging_dir"

cp -R "$app_path" "$staging_dir/Kod.app"
cp "$repository_root/THIRD_PARTY_NOTICES.md" "$staging_dir/THIRD_PARTY_NOTICES.md"
mkdir -p "$staging_dir/THIRD_PARTY_LICENSES"
cp "$repository_root/Packages/KodCore/Sources/CCMarkGFM/LICENSE-cmark-gfm.txt" \
    "$staging_dir/THIRD_PARTY_LICENSES/cmark-gfm-COPYING.txt"
cp "$repository_root/Vendor/Licenses/github-markdown-css-LICENSE.txt" \
    "$staging_dir/THIRD_PARTY_LICENSES/github-markdown-css-LICENSE.txt"
ln -s /Applications "$staging_dir/Applications"

zip_path="$output_dir/Kod-$version-$architecture.zip"
printf '%s\n' "==> Creating $zip_path"
rm -f "$zip_path"
/usr/bin/ditto -c -k --keepParent "$staging_dir/Kod.app" "$zip_path.app-only.zip"
(cd "$staging_dir" && /usr/bin/zip -qr "../$(basename "$zip_path")" "Kod.app" "THIRD_PARTY_NOTICES.md" "THIRD_PARTY_LICENSES")
rm -f "$zip_path.app-only.zip"

dmg_path="$output_dir/Kod-$version-$architecture.dmg"
printf '%s\n' "==> Creating $dmg_path"
rm -f "$dmg_path"
hdiutil create \
    -volname "Kod $version" \
    -srcfolder "$staging_dir" \
    -ov \
    -format UDZO \
    "$dmg_path"

rm -rf "$staging_dir"
printf '%s\n' "==> Packaged: $zip_path"
printf '%s\n' "==> Packaged: $dmg_path"
