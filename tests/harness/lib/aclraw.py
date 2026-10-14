#!/usr/bin/env python3
"""print the permission-list attributes of every path under the given folders, losslessly.

one line per path: the path as hex (so a newline or a backslash in a name cannot break the line),
the file type, and the raw access and default list attributes as hex. with --attributes the owner,
group, and full mode (special bits included) are added. used by the harness to compare two moments
of the machine; it only reads, and never follows a symbolic link.
"""
import os
import stat
import sys


def attribute(path, name):
    try:
        return os.getxattr(path, name, follow_symlinks=False).hex()
    except OSError:
        return "-"


def describe(path, with_attributes):
    info = os.lstat(path)
    kind = stat.S_IFMT(info.st_mode)
    fields = [os.fsencode(path).hex(), "%o" % kind]
    if kind != stat.S_IFLNK:
        fields += [attribute(path, "system.posix_acl_access"), attribute(path, "system.posix_acl_default")]
    else:
        fields += ["-", "-"]
    if with_attributes:
        fields += ["%d:%d" % (info.st_uid, info.st_gid), "%o" % stat.S_IMODE(info.st_mode)]
    return " ".join(fields)


def main(arguments):
    with_attributes = "--attributes" in arguments
    roots = [argument for argument in arguments if not argument.startswith("--")]
    lines = []
    for root in roots:
        lines.append(describe(root, with_attributes))
        for folder, names, files in os.walk(os.fsencode(root), followlinks=False):
            for name in names + files:
                lines.append(describe(os.path.join(folder, name), with_attributes))
    print("\n".join(sorted(lines)))


main(sys.argv[1:])
