"""Run the root gate's checker against made-up accounts, for tests/unit/test_gate.sh.

    gate_fake.py run     CHECKER SPEC FOLDER OWNER   judge FOLDER the way the gate does; prints what the checker prints, exits with its status
    gate_fake.py outsiders CHECKER SPEC OWNER NUMBER...  print, as JSON, who outsiders(NUMBER) names for each group number

CHECKER is the python text of the gate's checker (the here-document of sirven_vet), SPEC is a JSON file:
    accounts   [[name, user number, group number or "folder", shell], ...]  added to root and the owner
    members    {"group number": [names listed in the group file]}
    shadow     text of a made-up /etc/shadow (absent: no such file)
    login_defs text of a made-up /etc/login.defs (absent: no such file)
    acl        {"path below the folder, or . for the folder": [[tag, permission, id], ...]}  made-up access lists
The real passwd and group databases are replaced, so the folders being judged can be ordinary ones the test made.
"""
import json
import os
import pwd as real_pwd
import struct
import sys
import tempfile
import types

mode, checker_path, spec_path = sys.argv[1:4]
spec = json.load(open(spec_path))
text = open(checker_path).read()
folder = sys.argv[4] if mode == "run" else "/"
owner = sys.argv[5] if mode == "run" else sys.argv[4]
gids = sys.argv[5:] if mode == "outsiders" else []


class Entry:
    def __init__(self, name, uid, gid, shell):
        self.pw_name, self.pw_uid, self.pw_gid, self.pw_shell = name, uid, gid, shell


accounts = [Entry("root", 0, 0, "/bin/sh")]
try:
    real = real_pwd.getpwnam(owner)
    accounts.append(Entry(real.pw_name, real.pw_uid, real.pw_gid, real.pw_shell))
except KeyError:
    pass
for name, uid, gid, shell in spec.get("accounts", []):
    accounts.append(Entry(name, uid, os.lstat(folder).st_gid if gid == "folder" else gid, shell))

fake_pwd = types.ModuleType("pwd")


def getpwnam(name):
    for entry in accounts:
        if entry.pw_name == name:
            return entry
    raise KeyError(name)


def getpwuid(number):
    for entry in accounts:
        if entry.pw_uid == number:
            return entry
    return real_pwd.getpwuid(number)


fake_pwd.getpwnam, fake_pwd.getpwuid, fake_pwd.getpwall = getpwnam, getpwuid, lambda: list(accounts)
fake_grp = types.ModuleType("grp")
fake_grp.getgrgid = lambda number: types.SimpleNamespace(gr_name="g%d" % number, gr_mem=list(spec.get("members", {}).get(str(number), [])))
sys.modules["pwd"], sys.modules["grp"] = fake_pwd, fake_grp

scratch = tempfile.mkdtemp()
for key, constant in (("shadow", '"/etc/shadow"'), ("login_defs", '"/etc/login.defs"')):
    path = os.path.join(scratch, key)
    if key in spec:
        with open(path, "w") as handle:
            handle.write(spec[key])
    text = text.replace(constant, repr(path))

if "acl" in spec:
    def getxattr(path, name, follow_symlinks=True):
        relative = os.path.relpath(path, os.path.realpath(folder))
        if relative not in spec["acl"]:
            raise OSError(61, "no data")
        return struct.pack("<I", 2) + b"".join(struct.pack("<HHI", *entry) for entry in spec["acl"][relative])
    os.getxattr = getxattr

if mode == "run":
    sys.argv = ["-", folder, owner]
    exec(compile(text, "checker", "exec"), {"__name__": "__main__"})
else:
    sys.argv = ["-", "/", owner]
    space = {"__name__": "__main__"}
    exec(compile(text.split("problems = []")[0], "checker", "exec"), space)
    print(json.dumps({gid: space["outsiders"](int(gid)) for gid in gids}, sort_keys=True))
