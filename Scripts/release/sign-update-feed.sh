#!/bin/sh
# Signs Kod's update feed using UpdateFeedTool. This is release/test tooling only — the
# production signing key seed must come from an offline, protected
# source (a hardware key/secrets manager), never a file committed to
# this repository, and never an environment variable left set outside
# the one command below.
#
# Usage:
#   KOD_UPDATE_FEED_SIGNING_KEY_SEED_BASE64=... KOD_UPDATE_FEED_SIGNING_KEY_ID=2026-08 \
#     Scripts/release/sign-update-feed.sh feed.json signed-feed.json

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
feed_path=${1:-}
output_path=${2:-}

if [ -z "$feed_path" ] || [ -z "$output_path" ]; then
    printf '%s\n' "Usage: $0 <feed.json> <signed-feed.json>" >&2
    exit 64
fi

if [ -z "${KOD_UPDATE_FEED_SIGNING_KEY_SEED_BASE64:-}" ] || [ -z "${KOD_UPDATE_FEED_SIGNING_KEY_ID:-}" ]; then
    printf '%s\n' "BLOCKED: KOD_UPDATE_FEED_SIGNING_KEY_SEED_BASE64 and/or KOD_UPDATE_FEED_SIGNING_KEY_ID is not set." >&2
    printf '%s\n' "This environment has no production update-feed signing key (by design — see UpdaterCore's" >&2
    printf '%s\n' "UpdateFeedTrustRoot.production, which ships with an intentionally empty pinned-key list until" >&2
    printf '%s\n' "one exists). Generate a key pair offline with:" >&2
    printf '%s\n' "  swift run --package-path Packages/KodCore UpdateFeedTool generate-key" >&2
    printf '%s\n' "then set both variables (from a secrets manager, never a file in this repository) to proceed." >&2
    exit 78
fi

printf '%s\n' "==> Signing $feed_path with key ID $KOD_UPDATE_FEED_SIGNING_KEY_ID"
swift run --package-path "$repository_root/Packages/KodCore" UpdateFeedTool sign \
    --feed "$feed_path" \
    --key-seed-base64 "$KOD_UPDATE_FEED_SIGNING_KEY_SEED_BASE64" \
    --key-id "$KOD_UPDATE_FEED_SIGNING_KEY_ID" \
    --output "$output_path"

printf '%s\n' "==> Signed update feed written to $output_path"
printf '%s\n' "==> Reminder: publish the corresponding public key into UpdateFeedTrustRoot.production in a Kod release, with a validFrom matching this key's first signed feed's generatedAt."
