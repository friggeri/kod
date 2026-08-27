#!/bin/sh
# Writes SHA-256 checksums for every top-level published release file.
#
# Usage: Scripts/release/checksums.sh <artifacts-dir>

set -eu
set -o pipefail

artifacts_dir=${1:-}
if [ -z "$artifacts_dir" ] || [ ! -d "$artifacts_dir" ]; then
    printf '%s\n' "Usage: $0 <artifacts-dir>" >&2
    exit 64
fi

checksums_file="$artifacts_dir/SHA256SUMS.txt"
: > "$checksums_file"

find "$artifacts_dir" -maxdepth 1 -type f \
    ! -name "$(basename "$checksums_file")" \
    ! -name '.*' \
    -print | sort | while IFS= read -r artifact; do
        (cd "$artifacts_dir" && shasum -a 256 "$(basename "$artifact")") \
            >> "$checksums_file"
    done

if [ ! -s "$checksums_file" ]; then
    printf '%s\n' "No release artifacts were found in $artifacts_dir." >&2
    exit 65
fi

printf '%s\n' "==> Wrote $checksums_file"
