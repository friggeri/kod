#!/bin/sh
# Verifies an already Developer-ID-signed artifact, submits it to Apple's
# notarization service, and staples and validates the resulting ticket.
#
# Usage: Scripts/release/codesign-and-notarize.sh <Kod.app|Kod.dmg>

set -eu
set -o pipefail

artifact=${1:-}
if [ -z "$artifact" ] || [ ! -e "$artifact" ]; then
    printf '%s\n' "Usage: $0 <Kod.app|Kod.dmg>" >&2
    exit 64
fi

if [ -z "${KOD_CODE_SIGN_IDENTITY:-}" ]; then
    printf '%s\n' "BLOCKED: KOD_CODE_SIGN_IDENTITY is required to notarize." >&2
    exit 78
fi
if [ -z "${KOD_NOTARIZATION_KEYCHAIN_PROFILE:-}" ]; then
    if [ -z "${KOD_NOTARIZATION_API_KEY_PATH:-}" ] \
        || [ -z "${KOD_NOTARIZATION_API_KEY_ID:-}" ] \
        || [ -z "${KOD_NOTARIZATION_API_ISSUER_ID:-}" ]; then
        printf '%s\n' "BLOCKED: complete KOD_NOTARIZATION_API_KEY_* credentials are required when no keychain profile is provided." >&2
        exit 78
    fi
fi

require_developer_id() {
    target=$1
    signature_info=$(codesign -dvv "$target" 2>&1)
    if printf '%s\n' "$signature_info" | grep -q 'Signature=adhoc'; then
        printf '%s\n' "BLOCKED: refusing to notarize an ad-hoc-signed artifact: $target" >&2
        exit 65
    fi
    if ! printf '%s\n' "$signature_info" | grep -q 'Authority=Developer ID Application:'; then
        printf '%s\n' "BLOCKED: artifact is not signed by Developer ID Application: $target" >&2
        exit 65
    fi
}

submit_notarization() {
    submission=$1
    if [ -n "${KOD_NOTARIZATION_KEYCHAIN_PROFILE:-}" ]; then
        xcrun notarytool submit "$submission" \
            --keychain-profile "$KOD_NOTARIZATION_KEYCHAIN_PROFILE" \
            --wait \
            --output-format json
    else
        xcrun notarytool submit "$submission" \
            --key "$KOD_NOTARIZATION_API_KEY_PATH" \
            --key-id "$KOD_NOTARIZATION_API_KEY_ID" \
            --issuer "$KOD_NOTARIZATION_API_ISSUER_ID" \
            --wait \
            --output-format json
    fi
}

submission_path=$artifact
temporary_dir=
case "$artifact" in
    *.app)
        if [ ! -d "$artifact" ]; then
            printf '%s\n' "Expected an app bundle: $artifact" >&2
            exit 64
        fi
        codesign --verify --deep --strict --verbose=2 "$artifact"
        require_developer_id "$artifact"
        temporary_dir="${artifact%/}.notary-$$"
        mkdir -m 700 "$temporary_dir"
        trap 'rm -rf -- "$temporary_dir"' EXIT HUP INT TERM
        submission_path="$temporary_dir/Kod.zip"
        /usr/bin/ditto -c -k --keepParent "$artifact" "$submission_path"
        ;;
    *.dmg)
        printf '%s\n' "==> Signing DMG with Developer ID before notarization"
        codesign \
            --force \
            --timestamp \
            --sign "$KOD_CODE_SIGN_IDENTITY" \
            "$artifact"
        require_developer_id "$artifact"
        ;;
    *)
        printf '%s\n' "Unsupported notarization artifact: $artifact" >&2
        exit 64
        ;;
esac

printf '%s\n' "==> Submitting $(basename "$artifact") for notarization"
notarization_json=$(submit_notarization "$submission_path")
notarization_status=$(
    printf '%s\n' "$notarization_json" | python3 -c \
        'import json, sys; print(json.load(sys.stdin).get("status", ""))'
)
if [ "$notarization_status" != "Accepted" ]; then
    printf '%s\n' "BLOCKED: notarization did not accept $(basename "$artifact") (status: ${notarization_status:-unknown})." >&2
    printf '%s\n' "$notarization_json" >&2
    exit 65
fi

xcrun stapler staple "$artifact"
xcrun stapler validate "$artifact"
printf '%s\n' "==> Notarization and stapling complete: $artifact"
