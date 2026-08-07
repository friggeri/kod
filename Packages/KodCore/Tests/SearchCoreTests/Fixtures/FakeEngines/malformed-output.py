#!/usr/bin/env python3
"""Test double for the ripgrep engine: emits one valid begin/match pair and
then a line of garbage that is not valid JSON, exercising
WorkspaceTextSearcher's malformed-output handling end to end (real process,
real pipes) without depending on crafting a real ripgrep failure mode.
"""
import sys

print('{"type":"begin","data":{"path":{"text":"/workspace/example.txt"}}}', flush=True)
print(
    '{"type":"match","data":{"path":{"text":"/workspace/example.txt"},'
    '"lines":{"text":"needle here\\n"},"line_number":1,'
    '"submatches":[{"match":{"text":"needle"},"start":0,"end":6}]}}',
    flush=True,
)
print("this is not valid json at all {{{", flush=True)
sys.exit(0)
