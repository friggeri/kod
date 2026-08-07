#!/bin/sh
# Kod release-blocker audit (Phase 12). See audit.py's module docstring
# for the full list of checks. Read-only: writes only under
# Artifacts/release-blockers/.

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
exec python3 "$repository_root/Scripts/audit-release-blockers/audit.py" "$@"
