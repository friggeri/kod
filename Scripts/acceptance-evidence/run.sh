#!/bin/sh
# Kod release-qualification acceptance-evidence generator (SPEC 16.2).
#
# Thin wrapper around generate.py — see that file's module docstring for
# the full behavior. Usage:
#
#   Scripts/acceptance-evidence                    # fast pass (skips xcodebuild + 100k scale gate)
#   Scripts/acceptance-evidence --run-xcodebuild    # also runs xcodebuild -only-testing:KodAppTests
#   Scripts/acceptance-evidence --run-scale-tests   # also runs the 100k-file discovery scale gate
#
# Never launches KodAppUITests, Kod.app, XCUIApplication, AppleScript, or
# VoiceOver — this is a permanent constraint, identical to
# Scripts/verify-phase's own.

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
exec python3 "$repository_root/Scripts/acceptance-evidence/generate.py" "$@"
