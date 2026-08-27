#!/bin/sh
# Fail-closed identity and credential checks for a Kod production release.
# This script never signs, notarizes, or publishes.
#
# Usage: Scripts/release/preflight.sh <version>

set -eu
set -o pipefail

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
version=${1:-}

if [ -z "$version" ]; then
    printf '%s\n' "Usage: $0 <version>" >&2
    exit 64
fi
if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf '%s\n' "BLOCKED: release version must be a numeric semantic version: $version" >&2
    exit 64
fi

architecture=$(uname -m)
if [ "$architecture" != "arm64" ]; then
    printf '%s\n' "BLOCKED: Kod v0.1.x releases are Apple Silicon only; found $architecture." >&2
    exit 65
fi

if [ -n "${GITHUB_REPOSITORY:-}" ] && [ "$GITHUB_REPOSITORY" != "friggeri/kod" ]; then
    printf '%s\n' "BLOCKED: releases must be produced from friggeri/kod (found ${GITHUB_REPOSITORY})." >&2
    exit 65
fi

if git -C "$repository_root" remote get-url origin >/dev/null 2>&1; then
    origin_url=$(git -C "$repository_root" remote get-url origin)
    case "$origin_url" in
        *friggeri/kod*)
            ;;
        *)
            printf '%s\n' "BLOCKED: origin remote is not friggeri/kod: $origin_url" >&2
            exit 65
            ;;
    esac
fi

expected_tag="v$version"
if ! git -C "$repository_root" rev-parse --verify --quiet "refs/tags/$expected_tag" >/dev/null; then
    printf '%s\n' "BLOCKED: annotated tag $expected_tag does not exist locally." >&2
    exit 65
fi
if [ "$(git -C "$repository_root" cat-file -t "refs/tags/$expected_tag")" != "tag" ]; then
    printf '%s\n' "BLOCKED: $expected_tag must be an annotated tag." >&2
    exit 65
fi

actual_tag=$(git -C "$repository_root" describe --exact-match --tags HEAD 2>/dev/null || true)
if [ "$actual_tag" != "$expected_tag" ]; then
    printf '%s\n' "BLOCKED: HEAD must be the exact $expected_tag tag (found: ${actual_tag:-none})." >&2
    exit 65
fi

if [ -n "$(git -C "$repository_root" status --porcelain)" ]; then
    printf '%s\n' "BLOCKED: the release tree must be completely clean." >&2
    exit 65
fi

project_version=$(
    sed -n 's/^[[:space:]]*MARKETING_VERSION = \([^;]*\);/\1/p' \
        "$repository_root/Kod.xcodeproj/project.pbxproj" | sort -u
)
if [ "$project_version" != "$version" ]; then
    printf '%s\n' "BLOCKED: release version $version does not match MARKETING_VERSION $project_version." >&2
    exit 65
fi

if [ -z "${KOD_CODE_SIGN_IDENTITY:-}" ]; then
    printf '%s\n' "BLOCKED: KOD_CODE_SIGN_IDENTITY is not set." >&2
    exit 78
fi
if [ -z "${KOD_DEVELOPMENT_TEAM:-}" ]; then
    printf '%s\n' "BLOCKED: KOD_DEVELOPMENT_TEAM is not set." >&2
    exit 78
fi

if [ -z "${KOD_NOTARIZATION_KEYCHAIN_PROFILE:-}" ]; then
    if [ -z "${KOD_NOTARIZATION_API_KEY_PATH:-}" ] \
        || [ -z "${KOD_NOTARIZATION_API_KEY_ID:-}" ] \
        || [ -z "${KOD_NOTARIZATION_API_ISSUER_ID:-}" ]; then
        printf '%s\n' "BLOCKED: complete KOD_NOTARIZATION_API_KEY_* credentials are required when no keychain profile is provided." >&2
        exit 78
    fi
    if [ ! -f "$KOD_NOTARIZATION_API_KEY_PATH" ]; then
        printf '%s\n' "BLOCKED: KOD_NOTARIZATION_API_KEY_PATH does not exist." >&2
        exit 78
    fi
fi

if [ -z "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
    printf '%s\n' "BLOCKED: SPARKLE_PUBLIC_ED_KEY is not set." >&2
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

printf '%s\n' "==> Release preflight passed for $expected_tag (arm64, friggeri/kod)"
