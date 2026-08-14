#!/usr/bin/env python3
"""Emits one complete file, then waits for the test to permit process exit."""
import os
import time

with open("streaming-gated.pid", "w") as pid_file:
    pid_file.write(str(os.getpid()))

print('{"type":"begin","data":{"path":{"text":"./a.txt"}}}', flush=True)
print(
    '{"type":"match","data":{"path":{"text":"./a.txt"},'
    '"lines":{"text":"needle here\\n"},"line_number":1,'
    '"submatches":[{"match":{"text":"needle"},"start":0,"end":6}]}}',
    flush=True,
)
print('{"type":"end","data":{"path":{"text":"./a.txt"},"binary_offset":null,"stats":{}}}', flush=True)

with open("streaming-gated.ready", "w") as ready_file:
    ready_file.write("ready")

while not os.path.exists("streaming-gated.release"):
    time.sleep(0.01)
