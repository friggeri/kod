#!/bin/sh
# Verifies a built, signed Kod.app against Gatekeeper's static
# assessment (`spctl -a`) — the same check macOS performs on first
# launch of a downloaded app.
#
# IMPORTANT, per this task's constraints: this is a *static* assessment
# only. It never launches Kod.app, never drives its UI, and is not a
# substitute for the real acceptance test SPEC 16.2 #14 actually
# requires: opening the notarized build on a clean, network-connected
# Mac (ideally on both the oldest-supported and current macOS major
# version, per SPEC 12.1) and confirming Gatekeeper accepts it *and*
# the app actually launches and is usable. That real test requires
# physical hardware this environment does not have and is never
# performed by this script or claimed to have been performed.
#
# Usage: Scripts/release/verify-gatekeeper.sh <path-to-Kod.app>

set -eu

app_path=${1:-}
if [ -z "$app_path" ] || [ ! -d "$app_path" ]; then
    printf '%s\n' "Usage: $0 <path-to-Kod.app>" >&2
    exit 64
fi

printf '%s\n' "==> Static Gatekeeper assessment (spctl) for $app_path"
printf '%s\n' "==> NOTE: this is a static check only, run on this build machine — it is not a real clean-Mac launch test."
if spctl -a -vvv --type execute "$app_path"; then
    printf '%s\n' "==> spctl accepted $app_path"
    exit 0
else
    status=$?
    printf '%s\n' "==> spctl rejected $app_path (exit $status)." >&2
    printf '%s\n' "==> Expected unless the app was both signed with a real Developer ID identity AND successfully notarized+stapled (see codesign-and-notarize.sh)." >&2
    exit "$status"
fi
