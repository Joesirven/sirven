#!/usr/bin/env python3
"""kill switch helper: take away the agent's SSH keys without following a link.

standard library python, linux only, started by the kill switch plan (lib/kill_switch.sh) as root.

  remove-keys HOME
      remove the agent's authorized_keys and authorized_keys2 by name. the home folder is opened
      without following a link, then .ssh inside it, and each key file is removed with unlinkat
      from that descriptor, so a name the agent turned into a link is removed as a name and the
      file it pointed at is never opened, read, truncated or changed. when .ssh itself is a link
      (the agent swapped it), the link name is removed from the home folder. prints what it did.
  remove-ssh-folder HOME
      remove the .ssh folder of the agent when it is empty (uninstall), by the same no-follow walk: a .ssh that is a
      link is removed as a name, a folder with anything left in it is kept and said so, nothing is followed.
  keys-gone HOME
      read only. exit 0 when no key file and no .ssh link is left, by the same no-follow walk.

the agent owns its home folder and its .ssh folder, so every name in them may be a link it planted.
nothing here is done by path below the home folder, and nothing is truncated: a key file is removed,
not emptied, because emptying writes through a link.
"""

import errno
import os
import stat
import sys

KEY_FILES = ("authorized_keys", "authorized_keys2")
FOLDER = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)


class Failure(Exception):
    pass


def open_folder(name, parent=None):
    """open a folder without following a link: None when it is missing, a Failure when it is a link or not a folder."""
    try:
        if parent is None:
            return os.open(name, FOLDER)
        return os.open(name, FOLDER, dir_fd=parent)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise Failure("%s cannot be opened without following a link (%s)" % (name, error.strerror))


def entry(name, parent):
    try:
        return os.lstat(name, dir_fd=parent)
    except FileNotFoundError:
        return None


def count_keys(name, parent):
    """the number of key lines in a regular file, read without following a link."""
    try:
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0), dir_fd=parent)
    except OSError:
        return 0
    with os.fdopen(descriptor, "rb") as handle:
        lines = handle.read(1 << 20).splitlines()
    return sum(1 for line in lines if line.strip() and not line.lstrip().startswith(b"#"))


def command_remove_keys(home):
    base = open_folder(home)
    if base is None:
        print("no home folder %s, no keys to remove" % home)
        return 0
    try:
        found = entry(".ssh", base)
        if found is None:
            print("no .ssh folder in %s, no keys to remove" % home)
            return 0
        if stat.S_ISLNK(found.st_mode):
            os.unlink(".ssh", dir_fd=base)
            print("removed the link %s/.ssh (it was not a folder); what it pointed at was not opened or changed" % home)
            return 0
        ssh = open_folder(".ssh", base)
        if ssh is None:
            return 0
        try:
            for name in KEY_FILES:
                found = entry(name, ssh)
                if found is None:
                    continue
                if stat.S_ISDIR(found.st_mode):
                    print("left %s/.ssh/%s: it is a folder, and a folder authorizes nothing" % (home, name))
                    continue
                keys = count_keys(name, ssh) if stat.S_ISREG(found.st_mode) else 0
                kind = "link" if stat.S_ISLNK(found.st_mode) else "file"
                os.unlink(name, dir_fd=ssh)
                print("removed %s/.ssh/%s (a %s, %d keys); anything it pointed at was not opened or changed"
                      % (home, name, kind, keys))
        finally:
            os.close(ssh)
    finally:
        os.close(base)
    return 0


def command_remove_ssh_folder(home):
    base = open_folder(home)
    if base is None:
        return 0
    try:
        found = entry(".ssh", base)
        if found is None:
            return 0
        if stat.S_ISLNK(found.st_mode):
            os.unlink(".ssh", dir_fd=base)
            print("removed the link %s/.ssh (it was not a folder); what it pointed at was not opened or changed" % home)
            return 0
        if not stat.S_ISDIR(found.st_mode):
            print("       kept %s/.ssh: it is not a folder this package created" % home)
            return 0
        try:
            os.rmdir(".ssh", dir_fd=base)
        except OSError as error:
            if error.errno in (errno.ENOTEMPTY, errno.EEXIST):
                print("       kept %s/.ssh: it holds files this package did not create" % home)
                return 0
            raise
    finally:
        os.close(base)
    return 0


def command_keys_gone(home):
    base = open_folder(home)
    if base is None:
        return 0
    try:
        found = entry(".ssh", base)
        if found is None:
            return 0
        if stat.S_ISLNK(found.st_mode):
            return 1
        ssh = open_folder(".ssh", base)
        if ssh is None:
            return 0
        try:
            for name in KEY_FILES:
                found = entry(name, ssh)
                if found is not None and not stat.S_ISDIR(found.st_mode):
                    return 1
        finally:
            os.close(ssh)
    finally:
        os.close(base)
    return 0


def main(arguments):
    if len(arguments) != 2 or arguments[0] not in ("remove-keys", "remove-ssh-folder", "keys-gone"):
        sys.stderr.write("usage: kill_switch.py remove-keys|remove-ssh-folder|keys-gone HOME\n")
        return 2
    try:
        if arguments[0] == "remove-keys":
            return command_remove_keys(arguments[1])
        if arguments[0] == "remove-ssh-folder":
            return command_remove_ssh_folder(arguments[1])
        return command_keys_gone(arguments[1])
    except Failure as error:
        sys.stderr.write("error: %s\n" % error)
        sys.stderr.write("recovery: look at %s as root (ls -la), remove the link or odd entry by hand "
                         "(rm, never rm -r through a link), and run the same command again\n" % arguments[1])
        return 1
    except OSError as error:
        sys.stderr.write("error: %s: %s\n" % (error.filename or arguments[1], error.strerror))
        sys.stderr.write("recovery: fix the cause above and run revoke --all again; the account stays locked meanwhile\n")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
