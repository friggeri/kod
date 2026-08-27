#!/bin/sh
# Builds Kod's production, Developer-ID-signed Apple Silicon archive.
#
# Usage: Scripts/release/build-archive.sh <output-dir> <version>

set -eu
set -o pipefail

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
output_dir=${1:-}
version=${2:-}

if [ -z "$output_dir" ] || [ -z "$version" ]; then
    printf '%s\n' "Usage: $0 <output-dir> <version>" >&2
    exit 64
fi

if [ -z "${KOD_CODE_SIGN_IDENTITY:-}" ]; then
    printf '%s\n' "BLOCKED: KOD_CODE_SIGN_IDENTITY is not set." >&2
    exit 78
fi
if [ -z "${KOD_DEVELOPMENT_TEAM:-}" ]; then
    printf '%s\n' "BLOCKED: KOD_DEVELOPMENT_TEAM is not set." >&2
    exit 78
fi
if [ -z "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
    printf '%s\n' "BLOCKED: SPARKLE_PUBLIC_ED_KEY is not set." >&2
    exit 78
fi
if [ -z "${KOD_SWIFTPM_CLONED_SOURCE_PACKAGES_DIR:-}" ] \
    || [ ! -d "$KOD_SWIFTPM_CLONED_SOURCE_PACKAGES_DIR" ]; then
    printf '%s\n' "BLOCKED: pre-resolved KOD_SWIFTPM_CLONED_SOURCE_PACKAGES_DIR is required." >&2
    exit 78
fi

if [ "$SPARKLE_PUBLIC_ED_KEY" = "REPLACE_WITH_SPARKLE_PUBLIC_KEY" ]; then
    printf '%s\n' "BLOCKED: SPARKLE_PUBLIC_ED_KEY is still the placeholder." >&2
    exit 78
fi
if ! SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" python3 -c \
    'import base64, os, sys; sys.exit(0 if len(base64.b64decode(os.environ["SPARKLE_PUBLIC_ED_KEY"], validate=True)) == 32 else 1)'
then
    printf '%s\n' "BLOCKED: SPARKLE_PUBLIC_ED_KEY is not a 32-byte EdDSA public key." >&2
    exit 78
fi

project_version=$(
    sed -n 's/^[[:space:]]*MARKETING_VERSION = \([^;]*\);/\1/p' \
        "$repository_root/Kod.xcodeproj/project.pbxproj" | sort -u
)
if [ "$project_version" != "$version" ]; then
    printf '%s\n' "Release version $version does not match MARKETING_VERSION $project_version." >&2
    exit 65
fi

mkdir -p "$output_dir"
archive_path="$output_dir/Kod.xcarchive"

printf '%s\n' "==> Archiving Kod $version (arm64) to $archive_path"
xcodebuild \
    -project "$repository_root/Kod.xcodeproj" \
    -scheme Kod \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$archive_path" \
    -clonedSourcePackagesDirPath "$KOD_SWIFTPM_CLONED_SOURCE_PACKAGES_DIR" \
    -disableAutomaticPackageResolution \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$KOD_CODE_SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$KOD_DEVELOPMENT_TEAM" \
    SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO \
    clean archive

app_path="$archive_path/Products/Applications/Kod.app"
strip -S -x "$app_path/Contents/MacOS/Kod"
bundled_rg=$(
    find "$app_path/Contents/Resources" -type f \
        -path '*/ripgrep/aarch64-apple-darwin/rg' -print
)
if [ -z "$bundled_rg" ] || [ "$(printf '%s\n' "$bundled_rg" | wc -l | tr -d ' ')" -ne 1 ]; then
    printf '%s\n' "BLOCKED: expected exactly one bundled arm64 ripgrep executable." >&2
    exit 65
fi

require_developer_id() {
    target=$1
    signature_info=$(codesign -dvv "$target" 2>&1)
    if printf '%s\n' "$signature_info" | grep -q 'Signature=adhoc'; then
        printf '%s\n' "BLOCKED: ad-hoc signature: $target" >&2
        exit 65
    fi
    if ! printf '%s\n' "$signature_info" | grep -q 'Authority=Developer ID Application:'; then
        printf '%s\n' "BLOCKED: not signed by Developer ID Application: $target" >&2
        exit 65
    fi
}

require_arm64_only() {
    target=$1
    architectures=$(lipo -archs "$target")
    if [ "$architectures" != "arm64" ]; then
        printf '%s\n' "BLOCKED: expected arm64-only code, found '$architectures': $target" >&2
        exit 65
    fi
}

sign_nested() {
    target=$1
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --preserve-metadata=entitlements,identifier \
        --sign "$KOD_CODE_SIGN_IDENTITY" \
        "$target"
}

sparkle_root="$app_path/Contents/Frameworks/Sparkle.framework"
if [ ! -d "$sparkle_root" ]; then
    printf '%s\n' "BLOCKED: Sparkle.framework is missing from the archive." >&2
    exit 65
fi
if [ -d "$sparkle_root/Versions/Current" ]; then
    sparkle_version_dir="$sparkle_root/Versions/Current"
elif [ -d "$sparkle_root/Versions/B" ]; then
    sparkle_version_dir="$sparkle_root/Versions/B"
else
    printf '%s\n' "BLOCKED: Sparkle.framework version directory is missing." >&2
    exit 65
fi
if [ ! -f "$sparkle_version_dir/Sparkle" ]; then
    printf '%s\n' "BLOCKED: Sparkle framework binary is missing." >&2
    exit 65
fi
if [ ! -e "$sparkle_version_dir/Autoupdate" ]; then
    printf '%s\n' "BLOCKED: Sparkle Autoupdate helper is missing." >&2
    exit 65
fi
if [ ! -d "$sparkle_version_dir/Updater.app" ]; then
    printf '%s\n' "BLOCKED: Sparkle Updater.app helper is missing." >&2
    exit 65
fi
if [ ! -f "$sparkle_version_dir/Updater.app/Contents/MacOS/Updater" ]; then
    printf '%s\n' "BLOCKED: Sparkle Updater helper executable is missing." >&2
    exit 65
fi
if [ ! -d "$sparkle_version_dir/XPCServices/Downloader.xpc" ]; then
    printf '%s\n' "BLOCKED: Sparkle Downloader.xpc helper is missing." >&2
    exit 65
fi
if [ ! -f "$sparkle_version_dir/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" ]; then
    printf '%s\n' "BLOCKED: Sparkle Downloader helper executable is missing." >&2
    exit 65
fi
if [ ! -d "$sparkle_version_dir/XPCServices/Installer.xpc" ]; then
    printf '%s\n' "BLOCKED: Sparkle Installer.xpc helper is missing." >&2
    exit 65
fi
if [ ! -f "$sparkle_version_dir/XPCServices/Installer.xpc/Contents/MacOS/Installer" ]; then
    printf '%s\n' "BLOCKED: Sparkle Installer helper executable is missing." >&2
    exit 65
fi

# Sparkle 2.9.6 ships universal arm64+x86_64 Mach-O helpers. Thin them
# to arm64 before inside-out Developer ID signing so the Apple-Silicon
# architecture gate can stay fail-closed.
printf '%s\n' "==> Thinning Sparkle Mach-O binaries to arm64"
"$repository_root/Scripts/release/thin-macho-arm64.sh" "$sparkle_root"
require_arm64_only "$sparkle_version_dir/Sparkle"
require_arm64_only "$sparkle_version_dir/Autoupdate"
require_arm64_only "$sparkle_version_dir/Updater.app/Contents/MacOS/Updater"
require_arm64_only "$sparkle_version_dir/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
require_arm64_only "$sparkle_version_dir/XPCServices/Installer.xpc/Contents/MacOS/Installer"

printf '%s\n' "==> Signing Sparkle helpers, bundled ripgrep, then Kod.app inside-out"
for xpc in \
    "$sparkle_version_dir/XPCServices/Downloader.xpc" \
    "$sparkle_version_dir/XPCServices/Installer.xpc"
do
    if [ -d "$xpc" ]; then
        if [ -d "$xpc/Contents/MacOS" ]; then
            for exe in "$xpc/Contents/MacOS"/*; do
                [ -f "$exe" ] || continue
                sign_nested "$exe"
            done
        fi
        sign_nested "$xpc"
    fi
done
if [ -d "$sparkle_version_dir/Updater.app/Contents/MacOS" ]; then
    for exe in "$sparkle_version_dir/Updater.app/Contents/MacOS"/*; do
        [ -f "$exe" ] || continue
        sign_nested "$exe"
    done
fi
sign_nested "$sparkle_version_dir/Updater.app"
sign_nested "$sparkle_version_dir/Autoupdate"
sign_nested "$sparkle_root"
sign_nested "$bundled_rg"
codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "$repository_root/App/KodApp/Configuration/Kod.entitlements" \
    --sign "$KOD_CODE_SIGN_IDENTITY" \
    "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"
require_developer_id "$app_path"
require_developer_id "$bundled_rg"
require_developer_id "$sparkle_root"
require_developer_id "$sparkle_version_dir/Autoupdate"
require_developer_id "$sparkle_version_dir/Updater.app"

while IFS= read -r candidate; do
    case "$(file -b "$candidate")" in
        *Mach-O*)
            require_arm64_only "$candidate"
            require_developer_id "$candidate"
            ;;
    esac
done <<EOF
$(find "$app_path" -type f)
EOF

printf '%s\n' "==> Signed archive complete: $app_path"
