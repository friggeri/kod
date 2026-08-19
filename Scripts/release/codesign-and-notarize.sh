#!/bin/sh
# Codesigns a built Kod.app with hardened runtime and Kod's entitlements,
# then submits it for Apple notarization, waits for the result, and
# staples the notarization ticket.
#
# This is the one release stage that genuinely requires a real Apple
# Developer ID Application signing certificate and App Store Connect
# API credentials — neither of which exist in this (or any) automated
# environment by design. This script therefore:
#
#   - Reads credentials *only* from environment variables or the
#     keychain (never from a file this repository ships, never
#     hard-coded) — KOD_CODE_SIGN_IDENTITY (a certificate common name
#     already present in the running Mac's keychain) and either
#     KOD_NOTARIZATION_KEYCHAIN_PROFILE (a profile name previously
#     stored via `xcrun notarytool store-credentials`) or
#     KOD_NOTARIZATION_API_KEY_PATH/KOD_NOTARIZATION_API_KEY_ID/
#     KOD_NOTARIZATION_API_ISSUER_ID (an App Store Connect API key).
#   - If none of those are set, prints exactly what is missing and
#     exits non-zero — it never signs with an ad hoc identity and
#     calls that "notarized," and it never fabricates a success.
#
# Usage: Scripts/release/codesign-and-notarize.sh <path-to-Kod.app>

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
app_path=${1:-}

if [ -z "$app_path" ] || [ ! -d "$app_path" ]; then
    printf '%s\n' "Usage: $0 <path-to-Kod.app>" >&2
    exit 64
fi

if [ -z "${KOD_CODE_SIGN_IDENTITY:-}" ]; then
    printf '%s\n' "BLOCKED: KOD_CODE_SIGN_IDENTITY is not set." >&2
    printf '%s\n' "This environment has no production Apple Developer ID Application signing certificate (by design — see this script's own header comment and Scripts/release/README.md)." >&2
    printf '%s\n' "Set KOD_CODE_SIGN_IDENTITY to a certificate common name already in the release machine's keychain to proceed." >&2
    exit 78
fi

if [ -z "${KOD_NOTARIZATION_KEYCHAIN_PROFILE:-}" ] && [ -z "${KOD_NOTARIZATION_API_KEY_PATH:-}" ]; then
    printf '%s\n' "BLOCKED: neither KOD_NOTARIZATION_KEYCHAIN_PROFILE nor KOD_NOTARIZATION_API_KEY_PATH is set." >&2
    printf '%s\n' "This environment has no production App Store Connect API notarization credential (by design)." >&2
    printf '%s\n' "Run 'xcrun notarytool store-credentials' on a release machine and set KOD_NOTARIZATION_KEYCHAIN_PROFILE, or set the three KOD_NOTARIZATION_API_KEY_* variables, to proceed." >&2
    exit 78
fi

printf '%s\n' "==> Codesigning $app_path with hardened runtime (identity: $KOD_CODE_SIGN_IDENTITY)"
codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --entitlements "$repository_root/App/KodApp/Configuration/Kod.entitlements" \
    --sign "$KOD_CODE_SIGN_IDENTITY" \
    "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"
printf '%s\n' "==> Codesign verification passed"

zip_path="${app_path%.app}-for-notarization.zip"
printf '%s\n' "==> Zipping $app_path for notarization submission"
/usr/bin/ditto -c -k --keepParent "$app_path" "$zip_path"

printf '%s\n' "==> Submitting to Apple notarization service"
if [ -n "${KOD_NOTARIZATION_KEYCHAIN_PROFILE:-}" ]; then
    xcrun notarytool submit "$zip_path" --keychain-profile "$KOD_NOTARIZATION_KEYCHAIN_PROFILE" --wait
else
    xcrun notarytool submit "$zip_path" \
        --key "$KOD_NOTARIZATION_API_KEY_PATH" \
        --key-id "$KOD_NOTARIZATION_API_KEY_ID" \
        --issuer "$KOD_NOTARIZATION_API_ISSUER_ID" \
        --wait
fi

printf '%s\n' "==> Stapling notarization ticket"
xcrun stapler staple "$app_path"

printf '%s\n' "==> Notarization complete for $app_path"
