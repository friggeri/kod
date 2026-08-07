#!/usr/bin/env python3
"""Test double for the ripgrep engine: streams valid match lines
indefinitely (far beyond any reasonable result cap) until it receives
SIGTERM, so tests can assert that WorkspaceTextSearcher's result-limit
enforcement and cancellation both actually terminate the child process
instead of waiting for it to exit on its own.

Writes its own pid to a sibling ".pid" file next to this script on startup,
so tests can verify (via kill(pid, 0)) that the process was actually
terminated rather than merely disconnected from.
"""
import os
import sys
import time

pid_file = __file__ + ".pid"
with open(pid_file, "w") as f:
    f.write(str(os.getpid()))

print('{"type":"begin","data":{"path":{"text":"/workspace/flood.txt"}}}', flush=True)
line_number = 0
while True:
    line_number += 1
    print(
        '{"type":"match","data":{"path":{"text":"/workspace/flood.txt"},'
        '"lines":{"text":"needle number %d\\n"},"line_number":%d,'
        '"submatches":[{"match":{"text":"needle"},"start":0,"end":6}]}}'
        % (line_number, line_number),
        flush=True,
    )
    time.sleep(0.001)
