#!/bin/sh
# Verifies that a Sparkle signing secret matches the built app and its appcast.
#
# Usage: Scripts/release/verify-sparkle-release.sh <Kod.app> <update.zip> <appcast.xml> <version>

set -eu
set -o pipefail

app_path=${1:-}
archive_path=${2:-}
appcast_path=${3:-}
version=${4:-}

if [ -z "$app_path" ] || [ -z "$archive_path" ] || [ -z "$appcast_path" ] || [ -z "$version" ]; then
    printf '%s\n' "Usage: $0 <Kod.app> <update.zip> <appcast.xml> <version>" >&2
    exit 64
fi
if [ ! -d "$app_path" ] || [ ! -f "$archive_path" ] || [ ! -f "$appcast_path" ]; then
    printf '%s\n' "BLOCKED: Sparkle verification inputs are missing." >&2
    exit 65
fi
if [ -z "${SPARKLE_PRIVATE_KEY:-}" ]; then
    printf '%s\n' "BLOCKED: SPARKLE_PRIVATE_KEY is required for Sparkle verification." >&2
    exit 78
fi
if [ -z "${KOD_SPARKLE_SIGN_UPDATE:-}" ] || [ ! -x "$KOD_SPARKLE_SIGN_UPDATE" ]; then
    printf '%s\n' "BLOCKED: KOD_SPARKLE_SIGN_UPDATE must name Sparkle 2.9.6's executable tool." >&2
    exit 78
fi

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
verifier="$repository_root/Scripts/release/verify-sparkle-signature.py"
if [ ! -x "$verifier" ]; then
    printf '%s\n' "BLOCKED: Sparkle signature verifier is missing or not executable." >&2
    exit 65
fi

info_plist="$app_path/Contents/Info.plist"
if [ ! -f "$info_plist" ]; then
    printf '%s\n' "BLOCKED: built app does not contain Info.plist." >&2
    exit 65
fi
public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info_plist")
if [ -z "$public_key" ] || [ "$public_key" = '$(SPARKLE_PUBLIC_ED_KEY)' ]; then
    printf '%s\n' "BLOCKED: built app does not embed a concrete SUPublicEDKey." >&2
    exit 65
fi

challenge_path="$(dirname -- "$appcast_path")/.sparkle-key-challenge-$$"
trap 'rm -f -- "$challenge_path"; unset SPARKLE_PRIVATE_KEY' EXIT HUP INT TERM
umask 077
printf '%s' 'Kod Sparkle signing-key verification challenge v1' > "$challenge_path"
challenge_signature=$(
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$KOD_SPARKLE_SIGN_UPDATE" \
        --ed-key-file - \
        -p \
        "$challenge_path"
)
python3 "$verifier" \
    --public-key "$public_key" \
    --file "$challenge_path" \
    --signature "$challenge_signature"

expected_url="https://github.com/friggeri/kod/releases/download/v$version/Kod-$version-arm64.zip"
python3 "$verifier" \
    --public-key "$public_key" \
    --appcast "$appcast_path" \
    --archive "$archive_path" \
    --expected-url "$expected_url"
printf '%s\n' "==> Sparkle private key, ZIP enclosure, and enclosure signature verified"
