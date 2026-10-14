#!/usr/bin/env python3
"""access control snapshot: check, record, and undo the linux access control lists a grant adds.

standard library python, started by lib/access_control_snapshot.sh. linux only.

  check   USER --tree FOLDER... --alone FOLDER...
      read only. refuse (exit 3, the paths on standard output) when the granted folders or the
      pass-through parents already hold access lists for other accounts, or a mask, that granting
      would widen. the agent's own and the folder owner's own entries (an earlier grant) are fine.
  record  SNAPSHOT FOLDER yes|no USER [--audit FILE]
      write the snapshot: the folder, its identity, and what the grant is about to change. refuses
      the same way check does.
  restore SNAPSHOT FOLDER yes|no USER [--audit FILE]
      remove exactly what the grant added and put back what the snapshot recorded. with no usable
      snapshot it still removes what the grant added, and warns loudly.
  status  SNAPSHOT FOLDER yes|no USER
      read only. exit 0 when the undo has nothing left to do: no snapshot and no entry of the agent.
  repair  FOLDER yes|no USER [--audit FILE]
      restore with no snapshot, for installs made before snapshots existed.

what undo changes, and nothing else: the named entries of the agent (and of the folder owner, where
the agent's entry is there too), and on folders the default list when it carries the agent's entry.
it never changes an owner, a group, or any mode bit, special bits included. when no named entry is
left on a path, the list collapses to a plain mode: the group bits become the group entry AND the
mask, which is what the group could really do, so an owner's later chmod 600 stays 600.

nothing is done by path. every folder and file is opened one step at a time with O_NOFOLLOW, from
the file descriptor of the folder above it, and the attribute is read and written on the open
descriptor. a symbolic link is never followed; the start folder must still be the folder the
snapshot recorded (same device and inode), or it is skipped with a warning.
"""

import argparse
import base64
import datetime
import errno
import json
import os
import pwd
import stat
import struct
import sys

ACCESS = "system.posix_acl_access"
DEFAULT = "system.posix_acl_default"
USER_OBJ, USER, GROUP_OBJ, GROUP, MASK, OTHER = 0x01, 0x02, 0x04, 0x08, 0x10, 0x20
NO_ID = 0xFFFFFFFF
FORMAT = 2
LISTED = 10

EXIT_FAILED = 1
EXIT_USAGE = 2
EXIT_REFUSED = 3


class Failure(Exception):
    pass


# ---- the kernel's list format: a version, then 8 byte entries (tag, permissions, number) ----

def parse(raw):
    if len(raw) < 4 or (len(raw) - 4) % 8 != 0 or struct.unpack_from("<I", raw, 0)[0] != 2:
        raise Failure("an access control list attribute in an unknown format")
    return [struct.unpack_from("<HHI", raw, 4 + 8 * index) for index in range((len(raw) - 4) // 8)]


def build(entries):
    ordered = sorted(entries, key=lambda e: (e[0], e[2] if e[0] in (USER, GROUP) else 0))
    return struct.pack("<I", 2) + b"".join(struct.pack("<HHI", *entry) for entry in ordered)


def read_list(fd, name):
    """the entries of one list attribute on an open descriptor, or None when there is none."""
    try:
        return parse(os.getxattr(fd, name))
    except OSError as error:
        if error.errno in (errno.ENODATA, errno.EOPNOTSUPP, errno.ENOTSUP):
            return None
        raise


def has_named(entries):
    return any(tag in (USER, GROUP) for tag, _, _ in entries)


# ---- walking without following a link ----

FOLDER_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_NOCTTY | os.O_CLOEXEC


def open_folder(path):
    """open an absolute path one component at a time, refusing a link in any component."""
    descriptor = os.open("/", FOLDER_FLAGS)
    try:
        for part in os.fsencode(path).split(b"/"):
            if not part:
                continue
            following = os.open(part, FOLDER_FLAGS, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = following
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def walk(folder_fd, path, visit, errors):
    """call visit(fd, info, path, is_folder) for the folder and everything below it. links, pipes,
    devices and sockets are skipped; a path that cannot be opened is reported, not fatal."""
    info = os.fstat(folder_fd)
    visit(folder_fd, info, path, True)
    try:
        names = os.listdir(folder_fd)
    except OSError as error:
        errors.append((path, "cannot list: %s" % error.strerror))
        return
    for name in names:
        child = path.rstrip(b"/") + b"/" + os.fsencode(name)
        try:
            before = os.stat(name, dir_fd=folder_fd, follow_symlinks=False)
            if stat.S_ISDIR(before.st_mode):
                descriptor = os.open(name, FOLDER_FLAGS, dir_fd=folder_fd)
            elif stat.S_ISREG(before.st_mode):
                descriptor = os.open(name, FILE_FLAGS, dir_fd=folder_fd)
            else:
                continue
        except FileNotFoundError:
            continue
        except OSError as error:
            if error.errno != errno.ELOOP:
                errors.append((child, error.strerror))
            continue
        try:
            opened = os.fstat(descriptor)
            if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino) or \
                    stat.S_IFMT(opened.st_mode) != stat.S_IFMT(before.st_mode):
                errors.append((child, "changed while it was being read"))
            elif stat.S_ISDIR(opened.st_mode):
                walk(descriptor, child, visit, errors)
            else:
                visit(descriptor, opened, child, False)
        except OSError as error:
            errors.append((child, error.strerror))
        finally:
            os.close(descriptor)


def start(path, recursive, visit, errors):
    """open the start folder and visit it, and everything below when recursive."""
    descriptor = open_folder(path)
    try:
        if recursive:
            walk(descriptor, os.fsencode(path), visit, errors)
        else:
            visit(descriptor, os.fstat(descriptor), os.fsencode(path), True)
    finally:
        os.close(descriptor)


# ---- who is who ----

def account_number(name):
    try:
        return pwd.getpwnam(name).pw_uid
    except KeyError:
        return None


def describe_user(number):
    try:
        return "user %d (%s)" % (number, pwd.getpwuid(number).pw_name)
    except KeyError:
        return "user %d" % number


def printable(path):
    return os.fsdecode(path).encode("utf-8", "backslashreplace").decode("utf-8").replace("\n", "\\n").replace("\t", "\\t")


def say(message):
    sys.stderr.write("%s\n" % message)


def audit_warning(audit, user, message):
    """a warning entry in the audit log, in the format lib/audit.sh writes. never created here."""
    if not audit or not os.path.isfile(audit):
        return
    entry = {
        "time": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "event": "warning", "user": user, "principal": "owner",
        "operation": "access control undo", "message": message,
    }
    try:
        with open(audit, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry) + "\n")
    except OSError:
        pass


class Warnings:
    def __init__(self, audit, user):
        self.audit, self.user, self.count = audit, user, 0

    def add(self, message):
        self.count += 1
        say("warning: %s" % message)
        audit_warning(self.audit, self.user, message)


# ---- what a grant may and may not meet ----

def problems_in(entries, ours, where):
    """why a list the grant would recalculate is not safe to grant over. empty means it is fine."""
    if not entries:
        return []
    found = []
    others = sorted({number for tag, _, number in entries if tag == USER and number not in ours})
    groups = sorted({number for tag, _, number in entries if tag == GROUP})
    if others:
        found.append("%s list has an entry for %s" % (where, ", ".join(describe_user(n) for n in others)))
    if groups:
        found.append("%s list has an entry for group %s" % (where, ", ".join(str(n) for n in groups)))
    own = [1 for tag, _, number in entries if tag == USER and number in ours]
    if any(tag == MASK for tag, _, _ in entries) and not own and not others and not groups:
        found.append("%s list has a mask" % where)
    return found


def scan(folder, recursive, user):
    """walk the folder once. returns (context, entries, refusals, errors)."""
    resolved = os.path.realpath(folder)
    descriptor = open_folder(resolved)
    try:
        info = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    agent = account_number(user)
    ours = {number for number in (agent, info.st_uid) if number is not None}
    context = {"resolved": resolved, "dev": info.st_dev, "ino": info.st_ino, "agent": agent, "owner": info.st_uid}
    entries, refusals, errors = [], [], []

    def visit(fd, item, path, is_folder):
        access = read_list(fd, ACCESS)
        default = read_list(fd, DEFAULT) if is_folder and recursive else None
        for reason in problems_in(access, ours, "access") + problems_in(default, ours, "default"):
            refusals.append((path, reason))
        record = {}
        if access is not None and (has_named(access) or any(tag == MASK for tag, _, _ in access)):
            record["access"] = base64.b64encode(build(access)).decode()
        if default is not None:
            record["default"] = base64.b64encode(build(default)).decode()
        if is_folder or "access" in record:
            record.update({"p": path.hex(), "d": item.st_dev, "i": item.st_ino, "k": "d" if is_folder else "f"})
            entries.append(record)

    start(resolved, recursive, visit, errors)
    return context, entries, refusals, errors


def print_refusals(refusals):
    for path, reason in refusals[:LISTED]:
        sys.stdout.write("  %s (%s)\n" % (printable(path), reason))
    if len(refusals) > LISTED:
        sys.stdout.write("  and %d more\n" % (len(refusals) - LISTED))


# ---- commands ----

def command_check(arguments):
    refusals, unreadable = [], []
    for recursive, folders in ((True, arguments.tree), (False, arguments.alone)):
        for folder in folders:
            if not os.path.isdir(folder):
                continue
            try:
                _, _, found, errors = scan(folder, recursive, arguments.user)
            except OSError as error:
                unreadable.append((os.fsencode(folder), error.strerror))
                continue
            refusals.extend(found)
            unreadable.extend(errors)
    if refusals:
        print_refusals(refusals)
        return EXIT_REFUSED
    if unreadable:
        for path, reason in unreadable[:LISTED]:
            sys.stdout.write("  %s (could not read: %s)\n" % (printable(path), reason))
        return EXIT_FAILED
    return 0


def command_record(arguments):
    recursive = arguments.recursive == "yes"
    context, entries, refusals, errors = scan(arguments.folder, recursive, arguments.user)
    if refusals:
        print_refusals(refusals)
        return EXIT_REFUSED
    if errors:
        for path, reason in errors[:LISTED]:
            say("error: %s: %s" % (printable(path), reason))
        return EXIT_FAILED
    document = {"format": FORMAT, "folder": os.fsencode(arguments.folder).hex(),
                "recursive": recursive, "context": context, "entries": entries}
    folder = os.path.dirname(arguments.snapshot)
    os.makedirs(folder, mode=0o700, exist_ok=True)
    os.chmod(folder, 0o700)
    temporary = arguments.snapshot + ".new"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(document, handle)
    os.replace(temporary, arguments.snapshot)
    return 0


def load_snapshot(path, folder, recursive, warnings):
    """the snapshot, or None with a warning saying why it cannot be used."""
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
        if document.get("format") != FORMAT or document.get("folder") != os.fsencode(folder).hex() \
                or document.get("recursive") != recursive:
            raise ValueError("it is not for this folder, or it is in an older format")
        document["by_identity"] = {(item["d"], item["i"]): item for item in document["entries"]}
        return document
    except FileNotFoundError:
        warnings.add("could not restore the earlier access control lists of %s: there is no snapshot at %s. "
                     "the entries the grant added are removed anyway; look at what is left with: getfacl -R -p %s"
                     % (folder, path, folder))
    except (OSError, ValueError, KeyError, TypeError) as error:
        warnings.add("could not restore the earlier access control lists of %s: the snapshot %s cannot be used (%s). "
                     "the entries the grant added are removed anyway; look at what is left with: getfacl -R -p %s"
                     % (folder, path, error, folder))
    return None


def undo_access(fd, agent, owner, recorded, changes):
    """take the grant's entries off one path's access list, collapse it when no named entry is left."""
    current = read_list(fd, ACCESS)
    if current is None:
        return
    has_agent = any(tag == USER and number == agent for tag, _, number in current)
    kept = [entry for entry in current
            if not (entry[0] == USER and (entry[2] == agent or (entry[2] == owner and has_agent)))]
    if len(kept) == len(current):
        return
    if recorded:
        before = parse(base64.b64decode(recorded))
        again = [entry for entry in before if entry[0] == USER and entry[2] in (agent, owner)]
        kept = kept + again
        masks = [entry[1] for entry in before if entry[0] == MASK]
        if again and masks:
            kept = [(tag, perm & masks[0], number) if tag == MASK else (tag, perm, number) for tag, perm, number in kept]
    if has_named(kept):
        os.setxattr(fd, ACCESS, build(kept))
    else:
        mask = next((perm for tag, perm, _ in kept if tag == MASK), 7)
        plain = [(tag, perm & mask if tag == GROUP_OBJ else perm, number) for tag, perm, number in kept if tag != MASK]
        os.setxattr(fd, ACCESS, build(plain))
    changes.append(1)


def undo_default(fd, agent, recorded, changes):
    """on a folder: drop the default list when it carries the agent's entry, put back the earlier one."""
    current = read_list(fd, DEFAULT)
    if current is None or not any(tag == USER and number == agent for tag, _, number in current):
        return
    if recorded:
        os.setxattr(fd, DEFAULT, base64.b64decode(recorded))
    else:
        os.removexattr(fd, DEFAULT)
    changes.append(1)


def command_restore(arguments):
    recursive = arguments.recursive == "yes"
    warnings = Warnings(arguments.audit, arguments.user)
    snapshot = None
    if arguments.snapshot:
        snapshot = load_snapshot(arguments.snapshot, arguments.folder, recursive, warnings)
    else:
        say("repairing %s: no snapshot is used, so lists the folder had before the grant cannot be put back" % arguments.folder)
    agent = account_number(arguments.user)
    if agent is None and snapshot:
        agent = snapshot["context"]["agent"]
    if agent is None:
        say("error: the account %s is gone and no snapshot names its number, so its entries cannot be found" % arguments.user)
        return EXIT_FAILED
    resolved = os.path.realpath(arguments.folder)
    if snapshot:
        if resolved != snapshot["context"]["resolved"]:
            warnings.add("%s now resolves to %s, not the %s it was granted as; it was not touched"
                         % (arguments.folder, resolved, snapshot["context"]["resolved"]))
            return 0
    elif resolved != arguments.folder.rstrip("/") and arguments.folder != "/":
        warnings.add("%s contains a symbolic link (it resolves to %s); with no snapshot to check it against, "
                     "it was not touched" % (arguments.folder, resolved))
        return 0
    try:
        descriptor = open_folder(resolved)
    except OSError as error:
        warnings.add("%s cannot be opened (%s); it was not touched" % (arguments.folder, error.strerror))
        return 0
    info = os.fstat(descriptor)
    os.close(descriptor)
    if snapshot and (info.st_dev, info.st_ino) != (snapshot["context"]["dev"], snapshot["context"]["ino"]):
        warnings.add("%s is not the folder that was recorded (it was replaced during the grant); it was not touched"
                     % arguments.folder)
        return 0
    owner = snapshot["context"]["owner"] if snapshot else info.st_uid
    recorded = snapshot["by_identity"] if snapshot else {}
    seen, changes, errors = set(), [], []

    def visit(fd, item, path, is_folder):
        seen.add((item.st_dev, item.st_ino))
        earlier = recorded.get((item.st_dev, item.st_ino), {})
        try:
            undo_access(fd, agent, owner, earlier.get("access"), changes)
            if is_folder and recursive:
                undo_default(fd, agent, earlier.get("default"), changes)
        except OSError as error:
            errors.append((path, error.strerror))

    start(resolved, recursive, visit, errors)
    warned = []
    for item in sorted((item for item in recorded.values() if item["k"] == "d"), key=lambda item: item["p"]):
        path = bytes.fromhex(item["p"])
        if any(path.startswith(prefix + b"/") for prefix in warned):
            continue
        try:
            now = os.lstat(path)
        except OSError:
            continue
        if stat.S_ISLNK(now.st_mode):
            warnings.add("%s was a folder when the grant was made and is now a symbolic link; the link was not followed"
                         % printable(path))
            warned.append(path)
        elif (now.st_dev, now.st_ino) != (item["d"], item["i"]):
            warnings.add("%s is not the folder that was recorded (it was replaced during the grant)" % printable(path))
            warned.append(path)
    for path, reason in errors[:LISTED]:
        say("error: %s: %s" % (printable(path), reason))
    if errors:
        return EXIT_FAILED
    if arguments.snapshot:
        # a snapshot that was used is spent; one that could not be used was already warned about.
        try:
            os.unlink(arguments.snapshot)
            os.rmdir(os.path.dirname(arguments.snapshot))
        except OSError:
            pass
    return 0


def command_status(arguments):
    recursive = arguments.recursive == "yes"
    if os.path.exists(arguments.snapshot):
        return 1
    agent = account_number(arguments.user)
    if agent is None or not os.path.isdir(arguments.folder):
        return 0
    left = []

    def visit(fd, item, path, is_folder):
        for name in (ACCESS, DEFAULT) if is_folder and recursive else (ACCESS,):
            entries = read_list(fd, name)
            if entries and any(tag == USER and number == agent for tag, _, number in entries):
                left.append(path)

    try:
        start(os.path.realpath(arguments.folder), recursive, visit, [])
    except OSError:
        return 1
    return 1 if left else 0


def parser():
    top = argparse.ArgumentParser(prog="access_control_snapshot.sh")
    commands = top.add_subparsers(dest="command")
    commands.required = True

    check = commands.add_parser("check")
    check.add_argument("user")
    check.add_argument("--tree", action="append", default=[])
    check.add_argument("--alone", action="append", default=[])

    for name in ("record", "restore", "status"):
        command = commands.add_parser(name)
        command.add_argument("snapshot")
        command.add_argument("folder")
        command.add_argument("recursive", choices=("yes", "no"))
        command.add_argument("user")
        if name != "status":
            command.add_argument("--audit", default="")

    repair = commands.add_parser("repair")
    repair.add_argument("folder")
    repair.add_argument("recursive", choices=("yes", "no"))
    repair.add_argument("user")
    repair.add_argument("--audit", default="")
    return top


def main(argv):
    sys.setrecursionlimit(10000)
    try:
        arguments = parser().parse_args(argv)
    except SystemExit as stop:
        return EXIT_USAGE if stop.code else 0
    if arguments.command == "repair":
        arguments.snapshot = ""
        arguments.command = "restore"
    try:
        return {"check": command_check, "record": command_record,
                "restore": command_restore, "status": command_status}[arguments.command](arguments)
    except (OSError, Failure) as error:
        say("error: %s" % error)
        return EXIT_FAILED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
