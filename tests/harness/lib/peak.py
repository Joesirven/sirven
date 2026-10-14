#!/usr/bin/env python3
"""peak.py COMMAND...: run the command, print its exit status and the peak memory (megabytes) of the largest
process it started, and exit with the command's status. used by the harness to bound memory."""
import resource
import subprocess
import sys

status = subprocess.run(sys.argv[1:]).returncode
peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024
print("peak-memory-mb %d exit %d" % (peak, status))
sys.exit(status)
