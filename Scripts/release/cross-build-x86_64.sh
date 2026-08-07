#!/bin/sh
# Cross-builds a Release .xcarchive for x86_64 (Intel best-effort, per
# SPEC "Architecture priority: Apple silicon first; Intel best-effort")
# on this Apple-silicon machine, using Xcode's standard cross-
# compilation (no Intel hardware is required to *build* for x86_64;
# only to run the result natively — see
# Scripts/release/run-intel-compatibility-check.sh and
# docs/intel-compatibility-report.md for what is and is not verified
# without real Intel hardware).

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
exec "$repository_root/Scripts/release/build-archive.sh" x86_64 "$repository_root/Artifacts/release/x86_64"
