#!/usr/bin/env python3
"""lost_subtree.py: run `repair` while a folder deep in the tree is moved away from under the walk.

layout: /srv/work/d1/.../d60, and 20 files beside d12 in d11. while the walk lists d60 (a hook on the listing, so
the timing is exact), d12 is moved out of the tree and d1 is renamed. d11 was let go long before (only the deepest
48 folders are kept open), so it can no longer be reached by its saved identity or by name. the walk must say so
and fail, not skip d11's files without a word. prints the exit status and the messages."""
import contextlib
import importlib.util
import io
import os
import sys

spec = importlib.util.spec_from_file_location("h", sys.argv[1])
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
ROOT = "/srv/work"
chain = lambda n: ROOT + "".join("/d%d" % i for i in range(1, n + 1))
target = os.stat(chain(60)).st_ino
real_listdir = os.listdir
fired = []


def hook(where):
    if isinstance(where, int) and not fired and os.fstat(where).st_ino == target:
        fired.append(1)
        os.makedirs("/srv/elsewhere", exist_ok=True)
        os.rename(chain(12), "/srv/elsewhere/d12")
        os.rename(ROOT + "/d1", ROOT + "/d1x")
    return real_listdir(where)


os.listdir = hook
errors = io.StringIO()
with contextlib.redirect_stderr(errors):
    status = h.main(["repair", ROOT, "yes", "agent"])
os.listdir = real_listdir
print("status=%d fired=%d" % (status, len(fired)))
print(errors.getvalue())
# put the tree back for the second run
os.rename("/srv/elsewhere/d12", chain(11) + "/d12")
os.rename(ROOT + "/d1x", ROOT + "/d1")
