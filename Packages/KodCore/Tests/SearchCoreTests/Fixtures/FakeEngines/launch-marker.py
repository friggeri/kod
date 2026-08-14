#!/usr/bin/env python3
"""Records launch and exits, allowing cancellation-before-run assertions."""
import os

with open("launch-marker.pid", "w") as pid_file:
    pid_file.write(str(os.getpid()))
