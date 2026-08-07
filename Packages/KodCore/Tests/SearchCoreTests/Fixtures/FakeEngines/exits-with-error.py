#!/usr/bin/env python3
"""Test double for the ripgrep engine: writes a diagnostic to stderr and
exits with code 2 (ripgrep's "real error" exit code, e.g. an invalid
pattern), emitting nothing on stdout — exercises
WorkspaceTextSearcher.SearchError.engineReported end to end.
"""
import sys

sys.stderr.write("fake-engine: simulated fatal error\n")
sys.exit(2)
