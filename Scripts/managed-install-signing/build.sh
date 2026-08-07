#!/bin/sh
# Builds ManagedCatalogTool (see README.md in this directory) and prints
# its path, so a release engineer can run
#   "$(Scripts/managed-install-signing/build.sh)" generate-key
# without hardcoding a SwiftPM build-output path.
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

swift build \
    --package-path "$repository_root/Packages/KodCore" \
    --product ManagedCatalogTool \
    >&2

swift build \
    --package-path "$repository_root/Packages/KodCore" \
    --product ManagedCatalogTool \
    --show-bin-path | tr -d '\n'
printf '%s\n' "/ManagedCatalogTool"
