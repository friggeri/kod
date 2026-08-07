#!/bin/sh
# Orchestrates Kod's full release-qualification pipeline end to end,
# running every stage this environment can safely and headlessly
# perform, and reporting — never fabricating — the outcome of every
# stage it cannot (missing production signing/notarization
# credentials, missing physical hardware). See Scripts/release/README.md
# for the full stage-by-stage explanation and exactly what each
# credential-gated stage still requires from a real release engineer.
#
# Usage: Scripts/release/package-release.sh [version]

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
release_scripts_dir="$repository_root/Scripts/release"
version=${1:-$(date +%Y.%m.%d)}
output_dir="$repository_root/Artifacts/release"

mkdir -p "$output_dir"

printf '%s\n' "==> [1/9] Building Apple-silicon (arm64) archive"
"$release_scripts_dir/build-archive.sh" arm64 "$output_dir/arm64"
arm64_app="$output_dir/arm64/Kod.xcarchive/Products/Applications/Kod.app"

printf '%s\n' "==> [2/9] Cross-building x86_64 (Intel best-effort) archive"
"$release_scripts_dir/cross-build-x86_64.sh"
x86_64_app="$output_dir/x86_64/Kod.xcarchive/Products/Applications/Kod.app"

printf '%s\n' "==> [3/9] Verifying clean-install/upgrade/rollback/offline/uninstall lifecycle (static, isolated temp roots)"
python3 "$release_scripts_dir/verify-install-lifecycle.py" "$arm64_app"

printf '%s\n' "==> [4/9] Generating SBOM"
python3 "$release_scripts_dir/generate-sbom.py" "$output_dir/sbom.json"

printf '%s\n' "==> [5/9] Attempting codesign + notarization (credential-gated; expected to report BLOCKED without production credentials)"
if ! "$release_scripts_dir/codesign-and-notarize.sh" "$arm64_app"; then
    printf '%s\n' "==> Notarization step reported blocked/failed — see message above. Continuing with the remaining, non-credential-gated stages using the ad-hoc-signed build." >&2
fi

printf '%s\n' "==> [6/9] Static Gatekeeper assessment (spctl; not a real clean-Mac test)"
"$release_scripts_dir/verify-gatekeeper.sh" "$arm64_app" || printf '%s\n' "==> spctl did not accept the (likely still ad-hoc-signed) build — expected until real notarization succeeds." >&2

printf '%s\n' "==> [7/9] Packaging DMG/ZIP for both architectures"
"$release_scripts_dir/make-dmg.sh" "$arm64_app" "$output_dir" "$version"
"$release_scripts_dir/make-dmg.sh" "$x86_64_app" "$output_dir" "$version"

printf '%s\n' "==> [8/9] Writing checksums and provenance"
"$release_scripts_dir/checksums.sh" "$output_dir"
for artifact in "$output_dir"/*.dmg; do
    [ -e "$artifact" ] || continue
    python3 "$release_scripts_dir/generate-provenance.py" "$artifact"
done

printf '%s\n' "==> [9/9] Generating Homebrew Cask template"
python3 "$release_scripts_dir/generate-homebrew-cask.py" "$version" "REPLACE_WITH_REAL_DMG_SHA256" "$output_dir/kod.rb"

printf '%s\n' "==> Release packaging pipeline complete. Artifacts in $output_dir."
printf '%s\n' "==> Remaining, credential-/hardware-gated steps for a real release: production Developer ID signing, real notarization, a real clean-Mac Gatekeeper launch test, and the manual VoiceOver checklist (docs/manual-voiceover-checklist.md)."
