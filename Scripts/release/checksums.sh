#!/bin/sh
# Writes SHA-256 checksums for every release artifact in a directory
# (DMGs, ZIPs, and the checksums file itself is excluded from its own
# listing) to <output-dir>/SHA256SUMS.txt, in the standard
# `shasum -a 256 -c`-verifiable format.
#
# Usage: Scripts/release/checksums.sh <artifacts-dir>

set -eu

artifacts_dir=${1:-}
if [ -z "$artifacts_dir" ] || [ ! -d "$artifacts_dir" ]; then
    printf '%s\n' "Usage: $0 <artifacts-dir>" >&2
    exit 64
fi

checksums_file="$artifacts_dir/SHA256SUMS.txt"
: > "$checksums_file"

find "$artifacts_dir" -maxdepth 1 -type f \( -name '*.dmg' -o -name '*.zip' \) | sort | while IFS= read -r artifact; do
    (cd "$artifacts_dir" && shasum -a 256 "$(basename "$artifact")") >> "$checksums_file"
done

printf '%s\n' "==> Wrote $checksums_file:"
cat "$checksums_file"
