#!/bin/sh
# Creates non-secret release metadata after all signed binary artifacts exist.
#
# Usage: Scripts/release/finalize-release.sh <version>

set -eu
set -o pipefail

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
release_scripts_dir="$repository_root/Scripts/release"
version=${1:-}
output_dir="$repository_root/Artifacts/release"

if [ -z "$version" ]; then
    printf '%s\n' "Usage: $0 <version>" >&2
    exit 64
fi
if [ -z "${KOD_CYCLONEDX_CLI:-}" ] || [ ! -x "$KOD_CYCLONEDX_CLI" ]; then
    printf '%s\n' "BLOCKED: KOD_CYCLONEDX_CLI must name the pinned CycloneDX validator." >&2
    exit 78
fi

for required in \
    "Kod-$version-arm64.dmg" \
    "Kod-$version-arm64.zip" \
    "Kod-$version-licenses.zip" \
    appcast.xml \
    install-lifecycle-report.json
do
    if [ ! -f "$output_dir/$required" ]; then
        printf '%s\n' "BLOCKED: missing required release artifact: $required" >&2
        exit 65
    fi
done

printf '%s\n' "==> Generating CycloneDX 1.5 SBOM"
python3 "$release_scripts_dir/generate-sbom.py" "$output_dir/sbom.cdx.json"
"$KOD_CYCLONEDX_CLI" validate \
    --input-file "$output_dir/sbom.cdx.json" \
    --input-format json \
    --input-version v1_5 \
    --fail-on-errors

printf '%s\n' "==> Generating provenance records"
for artifact in \
    "$output_dir/Kod-$version-arm64.dmg" \
    "$output_dir/Kod-$version-arm64.zip" \
    "$output_dir/appcast.xml" \
    "$output_dir/sbom.cdx.json" \
    "$output_dir/install-lifecycle-report.json"
do
    python3 "$release_scripts_dir/generate-provenance.py" "$artifact"
done

printf '%s\n' "==> Writing final checksums"
"$release_scripts_dir/checksums.sh" "$output_dir"
for required in \
    "Kod-$version-arm64.dmg" \
    "Kod-$version-arm64.zip" \
    "Kod-$version-licenses.zip" \
    appcast.xml \
    sbom.cdx.json \
    install-lifecycle-report.json \
    "Kod-$version-arm64.dmg.provenance.json" \
    "Kod-$version-arm64.zip.provenance.json" \
    appcast.xml.provenance.json \
    sbom.cdx.json.provenance.json \
    install-lifecycle-report.json.provenance.json
do
    if [ ! -f "$output_dir/$required" ]; then
        printf '%s\n' "BLOCKED: missing required release artifact: $required" >&2
        exit 65
    fi
done
while IFS= read -r checksum_line; do
    checksum_name=${checksum_line##* }
    case "$checksum_name" in
        SHA256SUMS.txt)
            printf '%s\n' "BLOCKED: checksum file must not checksum itself." >&2
            exit 65
            ;;
        *x86_64*|*intel*|*homebrew*|*bottle*)
            printf '%s\n' "BLOCKED: unexpected Intel/Homebrew artifact in checksums: $checksum_name" >&2
            exit 65
            ;;
    esac
done < "$output_dir/SHA256SUMS.txt"
for required in \
    "Kod-$version-arm64.dmg" \
    "Kod-$version-arm64.zip" \
    "Kod-$version-licenses.zip" \
    appcast.xml \
    sbom.cdx.json \
    install-lifecycle-report.json
do
    if ! grep -Eq "[[:space:]]$required\$" "$output_dir/SHA256SUMS.txt"; then
        printf '%s\n' "BLOCKED: SHA256SUMS.txt is missing $required" >&2
        exit 65
    fi
done

printf '%s\n' "==> Release artifacts complete in $output_dir"
