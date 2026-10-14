#!/usr/bin/env python3
"""trust: may the code in this folder be run as root?

standard library python, linux. started by lib/trust.sh before any other library is read.

  check FOLDER USER OWNER
      read only. exit 0 when nobody but root and OWNER can change the package files in FOLDER or replace anything
      on the way to FOLDER; exit 3 and print each place that someone else can write. USER (the agent) is never
      trusted, and neither is any other account.

a place can be written by an account other than root and the owner when: the account owns it (an owner can chmod),
the mode lets a group write and the group has a member besides root and the owner, the mode lets everyone write
(a sticky folder on the way, like /tmp, is allowed: it does not let anyone replace what another account made),
or an access control list names another user or group with write that the list's mask does not switch off.
a place on a read-only file system cannot be written by anyone.

what this cannot do: it is code in the same folder it examines. it protects against edits to the libraries, not
against an edited copy of the first script the owner starts. the way to be sure is to run the kept copy in
/var/lib/<package>/package, which only root can write (see docs/PERMISSIONS.md).
"""

import grp
import os
import pwd
import stat
import struct
import sys

ACCESS_LIST = "system.posix_acl_access"
USER, GROUP, MASK = 0x02, 0x08, 0x10
PACKAGE_FILES = ("install.sh", "uninstall.sh", "bin", "lib", "levels", "project.json", "components")


def trusted_ids(owner):
    users = {0}
    try:
        users.add(pwd.getpwnam(owner).pw_uid)
    except KeyError:
        pass
    return users


def group_trusted(gid, users):
    """a group is as trusted as its members: nobody in it but root and the owner."""
    try:
        members = set(grp.getgrgid(gid).gr_mem)
    except KeyError:
        return gid == 0
    for entry in pwd.getpwall():
        if entry.pw_gid == gid:
            members.add(entry.pw_name)
    allowed = set()
    for number in users:
        try:
            allowed.add(pwd.getpwuid(number).pw_name)
        except KeyError:
            pass
    return members <= allowed


def read_only(path):
    try:
        return bool(os.statvfs(path).f_flag & os.ST_RDONLY)
    except OSError:
        return False


def acl_entries(path):
    if not hasattr(os, "getxattr"):
        return []
    try:
        blob = os.getxattr(path, ACCESS_LIST, follow_symlinks=False)
    except OSError:
        return []
    entries = []
    for offset in range(4, len(blob) - 7, 8):
        tag, perm, number = struct.unpack_from("<HHI", blob, offset)
        entries.append((tag, perm, number))
    return entries


def writers(path, info, users, on_the_way):
    """why another account can change this place, or nothing."""
    if read_only(path):
        return None
    if info.st_uid not in users:
        return "owned by %s, who can change its mode" % uid_name(info.st_uid)
    mode = stat.S_IMODE(info.st_mode)
    if mode & 0o002 and not (on_the_way and mode & stat.S_ISVTX):
        return "writable by everyone (mode %o)" % mode
    if mode & 0o020 and not group_trusted(info.st_gid, users):
        return "writable by the group %s (mode %o), which has other members" % (gid_name(info.st_gid), mode)
    entries = acl_entries(path)
    mask = next((perm for tag, perm, _ in entries if tag == MASK), 7)
    for tag, perm, number in entries:
        if not (perm & mask & 0o2):
            continue
        if tag == USER and number not in users:
            return "an access list entry gives %s write" % uid_name(number)
        if tag == GROUP and not group_trusted(number, users):
            return "an access list entry gives the group %s write" % gid_name(number)
    return None


def uid_name(number):
    try:
        return pwd.getpwuid(number).pw_name
    except KeyError:
        return "user number %d" % number


def gid_name(number):
    try:
        return grp.getgrgid(number).gr_name
    except KeyError:
        return "group number %d" % number


def check(folder, owner):
    users = trusted_ids(owner)
    problems = []
    real = os.path.realpath(folder)
    parts = [""] + [part for part in real.split("/") if part]
    path = ""
    for index, part in enumerate(parts):
        path = path + "/" + part if part else "/"
        info = os.lstat(path)
        if stat.S_ISDIR(info.st_mode):
            reason = writers(path, info, users, on_the_way=index < len(parts) - 1)
            if reason:
                problems.append((path, reason))
    for name in PACKAGE_FILES:
        top = os.path.join(real, name)
        if not os.path.lexists(top):
            continue
        for current, folders, files in os.walk(top, followlinks=False):
            for item in [current] + [os.path.join(current, entry) for entry in folders + files]:
                info = os.lstat(item)
                if stat.S_ISLNK(info.st_mode):
                    if not os.path.realpath(item).startswith(real + "/"):
                        problems.append((item, "a link to %s, outside the package" % os.path.realpath(item)))
                    continue
                reason = writers(item, info, users, on_the_way=False)
                if reason:
                    problems.append((item, reason))
    seen, unique = set(), []
    for path, reason in problems:
        if path not in seen:
            seen.add(path)
            unique.append((path, reason))
    return unique


def main(arguments):
    if len(arguments) != 4 or arguments[0] != "check":
        sys.stderr.write("usage: trust.py check FOLDER USER OWNER\n")
        return 2
    folder, _user, owner = arguments[1:]
    try:
        problems = check(folder, owner)
    except OSError as error:
        sys.stdout.write("  %s: cannot be examined (%s)\n" % (error.filename or folder, error.strerror))
        return 3
    for path, reason in problems[:12]:
        sys.stdout.write("  %s: %s\n" % (path, reason))
    if len(problems) > 12:
        sys.stdout.write("  and %d more\n" % (len(problems) - 12))
    return 3 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
