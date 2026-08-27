#!/bin/sh
# Performs Gatekeeper's static assessment for a notarized app or DMG.
#
# Usage: Scripts/release/verify-gatekeeper.sh <Kod.app|Kod.dmg>

set -eu
set -o pipefail

artifact=${1:-}
if [ -z "$artifact" ] || [ ! -e "$artifact" ]; then
    printf '%s\n' "Usage: $0 <Kod.app|Kod.dmg>" >&2
    exit 64
fi

signature_info=$(codesign -dvv "$artifact" 2>&1)
if printf '%s\n' "$signature_info" | grep -q 'Signature=adhoc'; then
    printf '%s\n' "BLOCKED: Gatekeeper artifact is ad-hoc signed: $artifact" >&2
    exit 65
fi
if ! printf '%s\n' "$signature_info" | grep -q 'Authority=Developer ID Application:'; then
    printf '%s\n' "BLOCKED: Gatekeeper artifact is not Developer ID signed: $artifact" >&2
    exit 65
fi

case "$artifact" in
    *.app)
        spctl -a -vvv --type execute "$artifact"
        codesign --verify --deep --strict --verbose=2 "$artifact"
        ;;
    *.dmg)
        spctl -a -vvv -t open --context context:primary-signature "$artifact"
        ;;
    *)
        printf '%s\n' "Unsupported Gatekeeper artifact: $artifact" >&2
        exit 64
        ;;
esac

xcrun stapler validate "$artifact"
printf '%s\n' "==> Gatekeeper accepted $(basename "$artifact")"
