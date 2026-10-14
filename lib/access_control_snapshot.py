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
  grant-access  FOLDER yes|no USER PERMISSIONS [--snapshot FILE]
      give USER the permissions (letters r, w, x, X) on the folder and, when yes, everything inside it. the
      same walk as undo: by descriptor, never following a link. the mask is recalculated, as setfacl does.
  grant-default FOLDER USER PERMISSIONS [--snapshot FILE]
      on every folder in the tree, the default list that makes new files inherit the grant: the agent and
      the folder owner get the permissions, group and other get nothing, whatever the creator's umask.
  quiesce USER MARKER / release USER MARKER
      end every process of USER and lock and expire its account, remembering what it was in MARKER;
      release puts the account back as MARKER says. install and rollback wrap a re-grant in these.

what undo changes, and nothing else: the named entries of the agent (and of the folder owner, where
the agent's entry is there too), and on folders the default list when it carries the agent's entry.
it never changes an owner or a group, and never touches the owner bits, the other bits or the special
bits. when no named entry is left on a path, the list collapses to a plain mode: the group bits
become the group entry AND the mask, which is what the group could really do, so an owner's later
chmod 600 stays 600. the one deliberate exception: a chmod that widens the group bits while a mask
exists changes the mask only, so it does not outlast the grant (644 to 664 ends 644).

nothing is done by path, the grant and the check included. every folder and file is opened one step at
a time with O_NOFOLLOW, from the file descriptor of the folder above it, and the attribute is read and
written on the open descriptor. a symbolic link is never followed; the start folder must still be the folder the
snapshot recorded (same device and inode), or it is skipped with a warning.
"""

import argparse
import bisect
import datetime
import errno
import json
import os
import pwd
import resource
import stat
import struct
import subprocess
import sys
import time
import urllib.parse

try:
    import sqlite3
except ImportError:  # reported when a snapshot is needed, not at start
    sqlite3 = None

ACCESS = "system.posix_acl_access"
DEFAULT = "system.posix_acl_default"
USER_OBJ, USER, GROUP_OBJ, GROUP, MASK, OTHER = 0x01, 0x02, 0x04, 0x08, 0x10, 0x20
NO_ID = 0xFFFFFFFF
FORMAT = 4
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


HELD = 48  # the deepest folders kept open at once, so a tree of any depth needs about this many descriptors
MAX_DEPTH = 30000  # deeper than this is reported by name and skipped


class Frame:
    """one folder being walked. memory per folder is a few small values and its own name, never its path: the
    path is built only when something is printed. the listing is kept only while the folder is held open;
    a folder let go is listed again when it is reopened, and resumes after the last name it had read."""
    __slots__ = ("fd", "ident", "name", "names", "position", "last")

    def __init__(self, fd, ident, name, names):
        self.fd, self.ident, self.name = fd, ident, name
        self.names, self.position, self.last = names, 0, None


class Where:
    """a place in the tree, as the folders above it and a last name. the path is built by path(), when asked,
    from the walk's live frame list, so ask at once (inside visit or when recording an error)."""
    __slots__ = ("frames", "leaf")

    def __init__(self, frames, leaf=None):
        self.frames, self.leaf = frames, leaf

    @property
    def name(self):
        return self.leaf if self.leaf is not None else self.frames[-1].name

    def path(self):
        parts = [self.frames[0].name.rstrip(b"/")]
        parts.extend(b"/" + frame.name for frame in self.frames[1:])
        if self.leaf is not None:
            parts.append(b"/" + self.leaf)
        return b"".join(parts) or b"/"


def resolve(where):
    """bytes for a Where (built now) or for a path already in bytes."""
    return where.path() if isinstance(where, Where) else where


class Capped:
    """the first LISTED items of a list an agent could make as long as it likes, and a count of the rest, so
    reporting many problems never costs memory."""

    def __init__(self):
        self.items, self.count = [], 0

    def append(self, item):
        self.count += 1
        if len(self.items) < LISTED:
            self.items.append((resolve(item[0]), item[1]) if isinstance(item, tuple) else item)

    def merge(self, other):
        self.count += other.count
        self.items.extend(other.items[:max(0, LISTED - len(self.items))])

    def __len__(self):
        return self.count

    def __getitem__(self, index):
        return self.items[index]

    def __iter__(self):
        return iter(self.items)


def identity(info):
    return (info.st_dev, info.st_ino)


def reopen(frames, index):
    """a descriptor for frames[index] (its fd was let go): open the names from the nearest folder still held,
    one at a time with O_NOFOLLOW, checking each is the folder it was. None when the tree changed."""
    start_at = index
    while start_at > 0 and frames[start_at].fd is None:
        start_at -= 1
    fd = os.dup(frames[start_at].fd)
    try:
        for level in range(start_at + 1, index + 1):
            following = os.open(frames[level].name, FOLDER_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = following
            if identity(os.fstat(fd)) != frames[level].ident:
                raise OSError(errno.ESTALE, "the folder was moved")
        return fd
    except OSError:
        os.close(fd)
        return None


def relist(frame):
    """read a folder's names again, sorted, and resume after the last name it had read."""
    frame.names = sorted(os.listdir(frame.fd))
    frame.position = bisect.bisect_right(frame.names, frame.last) if frame.last is not None else 0


LOST = ("moved, replaced or removed while it was being read, so the names still to be read in it were not visited. "
        "run the same command again")


def walk(folder_fd, path, visit, errors, on_link=None):
    """call visit(handle, info, where, is_folder, parent) for the folder and everything below it. the handle is
    an open descriptor, or for a pipe, device, or socket a /proc/self/fd path naming one; where.name is the last
    name (the whole path for the start folder) and where.path() the path; parent is the (device, inode) of the
    folder it is in, None for the start folder. symbolic links are skipped (on_link is told of each one); a path
    that cannot be opened is reported, not fatal. a folder lost from under the walk is reported as an error.

    iterative, and bounded in memory whatever the depth or the names: only the deepest HELD folders are kept
    open, with their listings; a folder let go is opened again from the one below it ("..", checked against
    the identity recorded when it was first opened) and listed again."""
    root_info = os.fstat(folder_fd)
    root = Frame(folder_fd, identity(root_info), path, None)
    frames = [root]
    visit(folder_fd, root_info, Where(frames), True, None)
    try:
        root.names = sorted(os.listdir(folder_fd))
    except OSError as error:
        errors.append((Where(frames), "cannot list: %s" % error.strerror))
        return
    while frames:
        top = frames[-1]
        if top.fd is None:
            top.fd = reopen(frames, len(frames) - 1)
            if top.fd is None:
                errors.append((Where(frames), LOST))
                frames.pop()
                continue
        if top.names is None:
            try:
                relist(top)
            except OSError as error:
                errors.append((Where(frames), "cannot list: %s" % error.strerror))
                os.close(top.fd)
                frames.pop()
                continue
        if top.position >= len(top.names):
            frames.pop()
            if len(frames) > 0:
                if frames[-1].fd is None:
                    try:
                        parent_fd = os.open("..", FOLDER_FLAGS, dir_fd=top.fd)
                        if identity(os.fstat(parent_fd)) == frames[-1].ident:
                            frames[-1].fd = parent_fd
                        else:
                            os.close(parent_fd)
                    except OSError:
                        pass
                os.close(top.fd)
            continue
        name = top.names[top.position]
        top.position += 1
        top.last = name
        raw = os.fsencode(name)
        try:
            before = os.stat(name, dir_fd=top.fd, follow_symlinks=False)
            if stat.S_ISDIR(before.st_mode):
                descriptor = os.open(name, FOLDER_FLAGS, dir_fd=top.fd)
            elif stat.S_ISREG(before.st_mode):
                descriptor = os.open(name, FILE_FLAGS, dir_fd=top.fd)
            elif stat.S_ISFIFO(before.st_mode) or stat.S_ISSOCK(before.st_mode) or stat.S_ISCHR(before.st_mode) \
                    or stat.S_ISBLK(before.st_mode):
                # the grant gave these entries too, but opening a pipe or a device could block or act. an
                # O_PATH descriptor only names the object, and /proc/self/fd/N reaches its attributes.
                descriptor = os.open(name, os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=top.fd)
            else:
                if stat.S_ISLNK(before.st_mode) and on_link:
                    on_link(top.ident, raw, Where(frames, raw))
                continue
        except FileNotFoundError:
            continue
        except OSError as error:
            if error.errno == errno.ELOOP:
                if on_link:
                    on_link(top.ident, raw, Where(frames, raw))
            else:
                errors.append((Where(frames, raw), error.strerror))
            continue
        keep = False
        try:
            opened = os.fstat(descriptor)
            if identity(opened) != identity(before) or stat.S_IFMT(opened.st_mode) != stat.S_IFMT(before.st_mode):
                errors.append((Where(frames, raw), "changed while it was being read"))
            elif stat.S_ISDIR(opened.st_mode):
                if len(frames) >= MAX_DEPTH:
                    errors.append((Where(frames, raw), "deeper than %d levels, so it and everything in it was skipped. "
                                   "remove that folder (rm -r) and run the same command again" % MAX_DEPTH))
                else:
                    visit(descriptor, opened, Where(frames, raw), True, top.ident)
                    frames.append(Frame(descriptor, identity(opened), raw, sorted(os.listdir(descriptor))))
                    keep = True
                    if len(frames) > HELD + 1:
                        index = len(frames) - 2 - HELD
                        let_go = frames[index]
                        if let_go.fd is not None and index > 0:
                            os.close(let_go.fd)
                            let_go.fd = None
                            let_go.names = None
            elif stat.S_ISREG(opened.st_mode):
                visit(descriptor, opened, Where(frames, raw), False, top.ident)
            else:
                visit("/proc/self/fd/%d" % descriptor, opened, Where(frames, raw), False, top.ident)
        except OSError as error:
            errors.append((Where(frames, raw), error.strerror))
        finally:
            if not keep:
                os.close(descriptor)


def start(path, recursive, visit, errors, on_link=None):
    """open the start folder and visit it, and everything below when recursive."""
    descriptor = open_folder(path)
    try:
        if recursive:
            walk(descriptor, os.fsencode(path), visit, errors, on_link)
        else:
            info = os.fstat(descriptor)
            visit(descriptor, info, Where([Frame(descriptor, identity(info), os.fsencode(path), None)]), True, None)
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
    path = resolve(path)
    if len(path) > 400:  # a path an agent made very deep: show its two ends
        path = path[:150] + b"...(%d bytes)..." % (len(path) - 300) + path[-150:]
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

def letters(bits):
    return "".join(letter if bits & bit else "-" for letter, bit in (("r", 4), ("w", 2), ("x", 1)))


def problems_in(entries, ours, where):
    """why granting over a list would widen another account. empty means it is fine.

    a grant recalculates the mask. that widens a named entry for another account only when the entry has
    permission bits outside the mask it has now: they were switched off by the mask and would switch on.
    an entry inside the mask, however many, is not widened. the agent's and the folder owner's entries are
    not counted, and the group entry is not either: the grant narrows it to the old mask before it
    raises the mask (see access_with_grant), so it stays as closed as it was.
    """
    if not entries:
        return []
    mask = next((perm for tag, perm, _ in entries if tag == MASK), None)
    if mask is None:
        return []
    found = []
    for tag, perm, number in entries:
        outside = perm & ~mask & 7
        if outside and ((tag == USER and number not in ours) or tag == GROUP):
            who = describe_user(number) if tag == USER else "group %d" % number
            found.append("%s list: %s has %s but the mask is %s" % (where, who, letters(perm), letters(mask)))
    return found


def signed(number):
    """a device or inode number as the signed 64-bit integer sqlite stores."""
    return number - (1 << 64) if number >= (1 << 63) else number


def scan(folder, recursive, user, sink=None):
    """walk the folder once. returns (context, refusals, errors). when a sink is given it is called with a row for
    every path that holds a list the undo may need to put back: (dev, ino, kind, parent dev, parent ino, name,
    access list, default list). a path with no list costs nothing, so the snapshot is as large as the lists the
    tree already had, not as large as the tree."""
    resolved = os.path.realpath(folder)
    descriptor = open_folder(resolved)
    try:
        info = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    agent = account_number(user)
    ours = {number for number in (agent, info.st_uid) if number is not None}
    context = {"resolved": resolved, "dev": info.st_dev, "ino": info.st_ino, "agent": agent, "owner": info.st_uid}
    refusals, errors = Capped(), Capped()

    def visit(fd, item, where, is_folder, parent=None):
        access = read_list(fd, ACCESS)
        default = read_list(fd, DEFAULT) if is_folder and recursive else None
        # the agent owns what it made and can put any entry on it itself, so those paths never block a
        # change of level or a rollback.
        if item.st_uid != agent:
            for reason in problems_in(access, ours, "access") + problems_in(default, ours, "default"):
                refusals.append((where, reason))
        if sink is None:  # the check only looks for refusals; it keeps nothing for a snapshot
            return
        keep_access = access is not None and (has_named(access) or any(tag == MASK for tag, _, _ in access))
        if keep_access or default is not None:
            sink((signed(item.st_dev), signed(item.st_ino), "d" if is_folder else "f",
                  signed(parent[0]) if parent else None, signed(parent[1]) if parent else None,
                  where.name, build(access) if keep_access else None,
                  build(default) if default is not None else None))

    start(resolved, recursive, visit, errors)
    return context, refusals, errors


def print_refusals(refusals):
    for path, reason in refusals[:LISTED]:
        sys.stdout.write("  %s (%s)\n" % (printable(path), reason))
    if len(refusals) > LISTED:
        sys.stdout.write("  and %d more\n" % (len(refusals) - LISTED))


# ---- the grant, by descriptor ----

def parse_permissions(text):
    """letters r, w, x, X -> (bits, execute_only_when_already_executable)."""
    bits = (4 if "r" in text else 0) | (2 if "w" in text else 0) | (1 if "x" in text else 0)
    return bits, "X" in text


def mode_entries(mode):
    return [(USER_OBJ, (mode >> 6) & 7, NO_ID), (GROUP_OBJ, (mode >> 3) & 7, NO_ID), (OTHER, mode & 7, NO_ID)]


def mask_of(entries):
    """the mask setfacl calculates: every permission the group class can use."""
    mask = 0
    for tag, perm, _ in entries:
        if tag in (GROUP_OBJ, USER, GROUP):
            mask |= perm
    return mask


def with_entry(entries, tag, number, perm):
    return [entry for entry in entries if not (entry[0] == tag and entry[2] == number)] + [(tag, perm, number)]


def narrowed_to_mask(entries, agent):
    """keep every entry of the group class (group, other accounts) as closed as the mask makes it today.
    recalculating the mask would switch on bits that an old chmod or a narrow mask had switched off, so they
    are cleared first; what each account can really do does not change."""
    mask = next((perm for tag, perm, _ in entries if tag == MASK), None)
    if mask is None:
        return list(entries)
    return [(tag, perm & mask, number) if tag in (GROUP_OBJ, GROUP) or (tag == USER and number != agent) else (tag, perm, number)
            for tag, perm, number in entries]


def access_with_grant(current, mode, is_folder, agent, spec):
    """the access list after the agent gets the permissions. pure."""
    bits, conditional = parse_permissions(spec)
    entries = list(current) if current else mode_entries(mode)
    if conditional and (is_folder or any(perm & 1 for _, perm, _ in entries)):
        bits |= 1
    entries = narrowed_to_mask(entries, agent)
    entries = with_entry(entries, USER, agent, bits)
    entries = [entry for entry in entries if entry[0] != MASK]
    entries.append((MASK, mask_of(entries), NO_ID))
    return sorted(entries, key=lambda e: (e[0], e[2] if e[0] in (USER, GROUP) else 0))


def default_with_grant(default, access, mode, agent, owner, spec):
    """the default list of a folder after the grant: the agent and the owner get the permissions, group and
    other get nothing. a folder with no default list starts from its own access list. pure."""
    bits, conditional = parse_permissions(spec)
    if conditional:
        bits |= 1  # a default list is on a folder, and X gives a folder execute
    source = narrowed_to_mask(default, agent) if default else [entry for entry in (access or mode_entries(mode)) if entry[0] in (USER_OBJ, GROUP_OBJ, OTHER)]
    entries = [entry for entry in source if entry[0] != MASK]
    entries = [(tag, 0, number) if tag in (GROUP_OBJ, OTHER) else (tag, perm, number) for tag, perm, number in entries]
    entries = with_entry(entries, USER, agent, bits)
    if owner not in (0, agent):
        entries = with_entry(entries, USER, owner, bits)
    entries.append((MASK, mask_of(entries), NO_ID))
    return sorted(entries, key=lambda e: (e[0], e[2] if e[0] in (USER, GROUP) else 0))


def start_checked(arguments, recursive, visit, errors):
    """open the start folder like undo does and, when a snapshot is named, check it is the recorded one."""
    agent = account_number(arguments.user)
    if agent is None:
        raise Failure("the account %s does not exist" % arguments.user)
    resolved = os.path.realpath(arguments.folder)
    descriptor = open_folder(resolved)
    try:
        info = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if arguments.snapshot:
        try:
            snapshot = Snapshot(arguments.snapshot)
            context = snapshot.context
            snapshot.close()
        except (OSError, ValueError, KeyError, sqlite3.Error, Failure) as error:
            raise Failure("no usable snapshot at %s (%s), so %s is not changed" % (arguments.snapshot, error, arguments.folder))
        if (context["dev"], context["ino"], context["resolved"]) != (info.st_dev, info.st_ino, resolved):
            raise Failure("%s is not the folder that was recorded before the grant; it was not changed" % arguments.folder)
    start(resolved, recursive, visit, errors)
    return agent, info


def report_errors(errors):
    for path, reason in errors[:LISTED]:
        say("error: %s: %s" % (printable(path), reason))
    if len(errors) > LISTED:
        say("error: and %d more" % (len(errors) - LISTED))


def finish_changes(errors):
    report_errors(errors)
    return EXIT_FAILED if errors else 0


def command_grant_access(arguments):
    recursive = arguments.recursive == "yes"
    errors = Capped()

    def visit(handle, item, where, is_folder, parent=None):
        try:
            current = read_list(handle, ACCESS)
            wanted = access_with_grant(current, stat.S_IMODE(item.st_mode), is_folder, agent, arguments.permissions)
            if wanted != current:
                os.setxattr(handle, ACCESS, build(wanted))
        except OSError as error:
            errors.append((where, error.strerror))

    agent = account_number(arguments.user)
    start_checked(arguments, recursive, visit, errors)
    return finish_changes(errors)


def command_grant_default(arguments):
    errors = Capped()
    owner = []

    def visit(handle, item, where, is_folder, parent=None):
        if not is_folder:
            return
        try:
            if not owner:
                owner.append(item.st_uid)
            access = read_list(handle, ACCESS)
            wanted = default_with_grant(read_list(handle, DEFAULT), access, stat.S_IMODE(item.st_mode),
                                        agent, owner[0], arguments.permissions)
            if wanted != read_list(handle, DEFAULT):
                os.setxattr(handle, DEFAULT, build(wanted))
        except OSError as error:
            errors.append((where, error.strerror))

    agent = account_number(arguments.user)
    start_checked(arguments, True, visit, errors)
    return finish_changes(errors)


def agent_bits(entries, agent):
    return next((perm for tag, perm, number in entries or [] if tag == USER and number == agent), None)


def command_verify_access(arguments):
    """read only: exit 0 when every path in the tree already has the agent's entry as the grant would write it.
    the mask is not compared: an owner's chmod narrows it on purpose and a re-install must not undo that."""
    recursive = arguments.recursive == "yes"
    agent = account_number(arguments.user)
    if agent is None:
        return 1
    missing, errors = [], Capped()

    def visit(handle, item, where, is_folder, parent=None):
        try:
            current = read_list(handle, ACCESS)
            wanted = access_with_grant(current, stat.S_IMODE(item.st_mode), is_folder, agent, arguments.permissions)
            if agent_bits(current, agent) != agent_bits(wanted, agent):
                missing.append(1)
        except OSError as error:
            errors.append((where, error.strerror))

    start(os.path.realpath(arguments.folder), recursive, visit, errors)
    return 1 if missing or errors else 0


def command_verify_default(arguments):
    """read only: exit 0 when every folder in the tree has the default list the grant writes."""
    agent = account_number(arguments.user)
    if agent is None:
        return 1
    bad, errors, owner = [], Capped(), []

    def visit(handle, item, where, is_folder, parent=None):
        if not is_folder:
            return
        try:
            if not owner:
                owner.append(item.st_uid)
            current = read_list(handle, DEFAULT)
            wanted = default_with_grant(current, read_list(handle, ACCESS), stat.S_IMODE(item.st_mode),
                                        agent, owner[0], arguments.permissions)
            same = current is not None and all(
                (tag, perm) in [(t, p) for t, p, n in current if n == number]
                for tag, perm, number in wanted if tag in (USER, GROUP_OBJ, OTHER))
            if not same:
                bad.append(1)
        except OSError as error:
            errors.append((where, error.strerror))

    start(os.path.realpath(arguments.folder), True, visit, errors)
    return 1 if bad or errors else 0


# ---- the agent's account while access changes ----

def shadow_fields(user):
    result = subprocess.run(["getent", "shadow", user], capture_output=True, text=True)
    fields = result.stdout.strip().split(":")
    if result.returncode != 0 or len(fields) < 8:
        return None
    return fields


def command_quiesce(arguments):
    fields = shadow_fields(arguments.user)
    if fields is None:
        return 0
    if not os.path.exists(arguments.marker):
        os.makedirs(os.path.dirname(arguments.marker), mode=0o700, exist_ok=True)
        descriptor = os.open(arguments.marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump({"locked": fields[1].startswith("!"), "expire": fields[7]}, handle)
    if not fields[1].startswith("!"):
        subprocess.run(["usermod", "--lock", arguments.user], check=True)
    subprocess.run(["usermod", "--expiredate", "1", arguments.user], check=True)
    end_processes(arguments.user)
    return 0


def end_processes(user):
    """end every process of the user. one pass is not enough for a process that keeps starting others, so
    repeat until none is left, at most 20 times."""
    for _ in range(20):
        subprocess.run(["pkill", "-KILL", "-u", user])
        if subprocess.run(["pgrep", "-u", user], capture_output=True).returncode != 0:
            return
        time.sleep(0.05)
    raise Failure("processes of %s keep starting and could not all be ended after 20 tries. its account is locked "
                  "and expired, so no new login works; end them by hand (pkill -KILL -u %s) and run again" % (user, user))


def command_release(arguments):
    try:
        with open(arguments.marker, encoding="utf-8") as handle:
            before = json.load(handle)
    except FileNotFoundError:
        return 0
    if shadow_fields(arguments.user) is not None:
        if not before["locked"]:
            subprocess.run(["usermod", "--unlock", arguments.user], check=True)
        expire = ""
        if before["expire"]:
            expire = (datetime.date(1970, 1, 1) + datetime.timedelta(days=int(before["expire"]))).isoformat()
        subprocess.run(["usermod", "--expiredate", expire, arguments.user], check=True)
    os.unlink(arguments.marker)
    return 0


# ---- commands ----

def command_check(arguments):
    refusals, unreadable = Capped(), Capped()
    for recursive, folders in ((True, arguments.tree), (False, arguments.alone)):
        for folder in folders:
            if not os.path.isdir(folder):
                continue
            try:
                _, found, errors = scan(folder, recursive, arguments.user)
            except OSError as error:
                unreadable.append((os.fsencode(folder), error.strerror))
                continue
            refusals.merge(found)
            unreadable.merge(errors)
    if refusals:
        print_refusals(refusals)
        return EXIT_REFUSED
    if unreadable:
        for path, reason in unreadable[:LISTED]:
            sys.stdout.write("  %s (could not read: %s)\n" % (printable(path), reason))
        if len(unreadable) > LISTED:
            sys.stdout.write("  and %d more\n" % (len(unreadable) - LISTED))
        return EXIT_FAILED
    return 0


def command_record(arguments):
    recursive = arguments.recursive == "yes"
    if sqlite3 is None:
        raise Failure("python3 has no sqlite3 module, so a snapshot cannot be written")
    folder = os.path.dirname(arguments.snapshot)
    os.makedirs(folder, mode=0o700, exist_ok=True)
    os.chmod(folder, 0o700)
    temporary = arguments.snapshot + ".new"
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    os.close(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600))
    db = sqlite3.connect(temporary)
    try:
        db.execute("PRAGMA journal_mode = OFF")
        db.execute("PRAGMA synchronous = OFF")
        db.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
        db.execute("CREATE TABLE entries (dev INTEGER, ino INTEGER, kind TEXT, pdev INTEGER, pino INTEGER, "
                   "name BLOB, access BLOB, dflt BLOB)")
        batch = []

        def sink(row):  # written as the walk goes, 1,000 rows at a time
            batch.append(row)
            if len(batch) >= 1000:
                db.executemany("INSERT INTO entries VALUES (?, ?, ?, ?, ?, ?, ?, ?)", batch)
                del batch[:]

        context, refusals, errors = scan(arguments.folder, recursive, arguments.user, sink)
        status = 0
        if refusals:
            print_refusals(refusals)
            status = EXIT_REFUSED
        elif errors:
            report_errors(errors)
            status = EXIT_FAILED
        else:
            db.executemany("INSERT INTO entries VALUES (?, ?, ?, ?, ?, ?, ?, ?)", batch)
            db.execute("CREATE UNIQUE INDEX by_inode ON entries (dev, ino)")
            db.execute("CREATE INDEX by_place ON entries (pdev, pino, name)")
            db.executemany("INSERT INTO meta VALUES (?, ?)", [
                ("format", str(FORMAT)), ("folder", os.fsencode(arguments.folder).hex()),
                ("recursive", str(recursive)), ("context", json.dumps(context))])
            db.commit()
    except BaseException:
        db.close()
        os.unlink(temporary)
        raise
    db.close()
    if status != 0:
        os.unlink(temporary)
        return status
    os.replace(temporary, arguments.snapshot)
    return 0


class Snapshot:
    """a snapshot on disk (a sqlite file, root only). nothing is loaded into memory: the paths that held a list
    are looked up by device and inode as the walk meets them."""

    def __init__(self, path, folder=None, recursive=None):
        if sqlite3 is None:
            raise Failure("python3 has no sqlite3 module, so a snapshot cannot be read")
        self.db = sqlite3.connect("file:%s?mode=ro" % urllib.parse.quote(path), uri=True)
        try:
            meta = dict(self.db.execute("SELECT key, value FROM meta"))
        except sqlite3.DatabaseError as error:
            self.db.close()
            raise ValueError("it is not a snapshot of this version (%s)" % error)
        if meta.get("format") != str(FORMAT):
            self.db.close()
            raise ValueError("it is in another format (%s)" % meta.get("format"))
        if folder is not None and (meta.get("folder") != os.fsencode(folder).hex() or meta.get("recursive") != str(recursive)):
            self.db.close()
            raise ValueError("it is not for this folder")
        self.context = json.loads(meta["context"])
        self.rows = self.db.execute("SELECT COUNT(*) FROM entries").fetchone()[0]

    def earlier(self, device, inode):
        """(access list, default list) the path held before the grant, as raw attribute bytes, or (None, None)."""
        if not self.rows:
            return None, None
        row = self.db.execute("SELECT access, dflt FROM entries WHERE dev = ? AND ino = ?",
                              (signed(device), signed(inode))).fetchone()
        return row if row else (None, None)

    def folder_at(self, parent, name):
        """(device, inode) of the folder with this parent and name that held a list, or None."""
        if not self.rows or not parent:
            return None
        row = self.db.execute("SELECT dev, ino FROM entries WHERE kind = 'd' AND pdev = ? AND pino = ? AND name = ?",
                              (signed(parent[0]), signed(parent[1]), name)).fetchone()
        return (row[0] % (1 << 64), row[1] % (1 << 64)) if row else None

    def close(self):
        self.db.close()


def load_snapshot(path, folder, recursive, warnings):
    """the snapshot, or None with a warning saying why it cannot be used."""
    try:
        return Snapshot(path, folder, recursive)
    except FileNotFoundError:
        warnings.add("could not restore the earlier access control lists of %s: there is no snapshot at %s. "
                     "the entries the grant added are removed anyway; look at what is left with: getfacl -R -p %s"
                     % (folder, path, folder))
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error) as error:
        warnings.add("could not restore the earlier access control lists of %s: the snapshot %s cannot be used (%s). "
                     "the entries the grant added are removed anyway; look at what is left with: getfacl -R -p %s"
                     % (folder, path, error, folder))
    return None


def access_without_grant(current, agent, owner, recorded):
    """the access list a path should have once the grant's entries are gone, or None when the path
    holds none of them. pure: no file is touched here.

    the agent's named entries go, and the folder owner's where the agent's is there too. entries the
    path had before an earlier grant come back (with the mask no wider than before). with no named
    entry left, the list collapses to a plain mode: the group entry AND the mask, and no mask.
    """
    has_agent = any(tag == USER and number == agent for tag, _, number in current)
    kept = [entry for entry in current
            if not (entry[0] == USER and (entry[2] == agent or (entry[2] == owner and has_agent)))]
    if len(kept) == len(current):
        return None
    if recorded:
        before = parse(bytes(recorded))
        again = [entry for entry in before if entry[0] == USER and entry[2] in (agent, owner)]
        kept = kept + again
        masks = [entry[1] for entry in before if entry[0] == MASK]
        if masks:  # the mask it had, no wider: the grant raised it, and it must not stay raised
            kept = [(tag, perm & masks[0], number) if tag == MASK else (tag, perm, number) for tag, perm, number in kept]
    return collapsed(kept)


def collapsed(entries):
    """sorted entries; with no named entry left, a plain mode: the group entry AND the mask, and no mask."""
    kept = sorted(entries, key=lambda e: (e[0], e[2] if e[0] in (USER, GROUP) else 0))
    if has_named(kept):
        return kept
    mask = next((perm for tag, perm, _ in kept if tag == MASK), 7)
    return [(tag, perm & mask if tag == GROUP_OBJ else perm, number) for tag, perm, number in kept if tag != MASK]


def has_account(number):
    try:
        pwd.getpwuid(number)
        return True
    except KeyError:
        return False


def access_without_leftovers(current, owner):
    """for a machine where the agent's account is already gone: take off the entries for numbers that no
    account has, and the folder owner's, and collapse a list that is only a mask. None when nothing to do. pure
    apart from the account lookup."""
    kept = [entry for entry in current
            if not (entry[0] == USER and (entry[2] == owner or not has_account(entry[2])))]
    only_a_mask = not has_named(current) and any(tag == MASK for tag, _, _ in current)
    if len(kept) == len(current) and not only_a_mask:
        return None
    return collapsed(kept)


def default_is_leftover(current, owner):
    """a default list the grant wrote and an old undo left: it has a mask, and the only named entries are for
    the folder owner or for numbers no account has (the agent's was removed or its account is gone). the
    older grant copied the folder's own group and other bits into it, so those are not required to be closed.
    an ordinary default list has no mask unless it names someone, so it is not taken for a leftover."""
    if current is None:
        return False
    named_ours = all(number == owner or not has_account(number) for tag, _, number in current if tag == USER)
    return named_ours and any(tag == MASK for tag, _, _ in current)


def undo_access(fd, agent, owner, recorded, changes):
    """take the grant's entries off one path's access list."""
    current = read_list(fd, ACCESS)
    if current is None:
        return
    wanted = access_without_grant(current, agent, owner, recorded)
    if wanted is None:
        return
    os.setxattr(fd, ACCESS, build(wanted))
    changes.append(1)


def undo_default(fd, agent, recorded, changes):
    """on a folder: drop the default list when it carries the agent's entry, put back the earlier one."""
    current = read_list(fd, DEFAULT)
    if current is None or not any(tag == USER and number == agent for tag, _, number in current):
        return
    if recorded:
        os.setxattr(fd, DEFAULT, bytes(recorded))
    else:
        os.removexattr(fd, DEFAULT)
    changes.append(1)


def undo_leftovers(fd, owner, with_default, where, changes, dry):
    """the no-account form of undo for one path. records the path in changes; writes unless dry."""
    current = read_list(fd, ACCESS)
    wanted = access_without_leftovers(current, owner) if current else None
    default = read_list(fd, DEFAULT) if with_default else None
    drop_default = default_is_leftover(default, owner)
    if wanted is None and not drop_default:
        return
    changes.append((where, ""))
    if dry:
        return
    if wanted is not None:
        os.setxattr(fd, ACCESS, build(wanted))
    if drop_default:
        os.removexattr(fd, DEFAULT)


def restore_folder(arguments):
    recursive = arguments.recursive == "yes"
    warnings = Warnings(arguments.audit, arguments.user)
    snapshot = None
    if arguments.snapshot:
        snapshot = load_snapshot(arguments.snapshot, arguments.folder, recursive, warnings)
        arguments.opened = snapshot
    else:
        say("repairing %s: no snapshot is used, so lists the folder had before the grant cannot be put back" % arguments.folder)
    agent = account_number(arguments.user)
    if agent is None and snapshot:
        agent = snapshot.context["agent"]
    leftovers = agent is None
    if getattr(arguments, "dry_run", False) and not leftovers:
        say("dry run: nothing was changed. repair would remove the entries of %s (and the folder owner's, and the "
            "default list that carries them) under %s" % (arguments.user, arguments.folder))
        return 0
    if leftovers:
        say("the account %s is gone and no snapshot names its number, so this removes what an old undo left: entries "
            "for numbers no account has, the folder owner's entry, a mask with no entry, and the default list the "
            "grant wrote (group and other nothing)" % arguments.user)
    resolved = os.path.realpath(arguments.folder)
    if snapshot:
        if resolved != snapshot.context["resolved"]:
            warnings.add("%s now resolves to %s, not the %s it was granted as; it was not touched"
                         % (arguments.folder, resolved, snapshot.context["resolved"]))
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
    if snapshot and (info.st_dev, info.st_ino) != (snapshot.context["dev"], snapshot.context["ino"]):
        warnings.add("%s is not the folder that was recorded (it was replaced during the grant); it was not touched"
                     % arguments.folder)
        return 0
    owner = snapshot.context["owner"] if snapshot else info.st_uid
    changes, errors = Capped(), Capped()

    def replaced(parent, name, path, what):
        if snapshot and snapshot.folder_at(parent, name) is not None:
            warnings.add("%s was a folder when the grant was made and is now %s; it was not followed" % (printable(path), what))

    def visit(fd, item, where, is_folder, parent=None):
        earlier_access, earlier_default = snapshot.earlier(item.st_dev, item.st_ino) if snapshot else (None, None)
        if is_folder and parent and snapshot:
            place = snapshot.folder_at(parent, where.name)
            if place is not None and place != (item.st_dev, item.st_ino):
                warnings.add("%s is not the folder that was recorded (it was replaced during the grant)" % printable(where))
        try:
            if leftovers:
                undo_leftovers(fd, owner, is_folder and recursive, where, changes, getattr(arguments, "dry_run", False))
                return
            undo_access(fd, agent, owner, earlier_access, changes)
            if is_folder and recursive:
                undo_default(fd, agent, earlier_default, changes)
        except OSError as error:
            errors.append((where, error.strerror))

    start(resolved, recursive, visit, errors,
          lambda parent, name, path: replaced(parent, name, path, "a symbolic link"))
    if leftovers:
        for path, _ in changes[:LISTED]:
            say("%s %s" % ("would change" if getattr(arguments, "dry_run", False) else "changed", printable(path)))
        if len(changes) > LISTED:
            say("and %d more" % (len(changes) - LISTED))
        if not changes:
            say("nothing left to remove in %s" % arguments.folder)
    report_errors(errors)
    return EXIT_FAILED if errors else 0


def command_restore(arguments):
    arguments.opened = None
    try:
        status = restore_folder(arguments)
    finally:
        if arguments.opened is not None:
            arguments.opened.close()
    if status == 0 and arguments.snapshot:
        # a snapshot that was used is spent, and one that could not be used or applied was already warned
        # about, so none is kept: a rerun would only warn again.
        try:
            os.unlink(arguments.snapshot)
            os.rmdir(os.path.dirname(arguments.snapshot))
        except OSError:
            pass
    return status


def command_status(arguments):
    recursive = arguments.recursive == "yes"
    if os.path.exists(arguments.snapshot):
        return 1
    agent = account_number(arguments.user)
    if agent is None or not os.path.isdir(arguments.folder):
        return 0
    left = []

    def visit(fd, item, where, is_folder, parent=None):
        for name in (ACCESS, DEFAULT) if is_folder and recursive else (ACCESS,):
            entries = read_list(fd, name)
            if entries and any(tag == USER and number == agent for tag, _, number in entries):
                left.append(1)

    try:
        start(os.path.realpath(arguments.folder), recursive, visit, Capped())
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

    for name in ("grant-access", "grant-default"):
        command = commands.add_parser(name)
        command.add_argument("folder")
        if name == "grant-access":
            command.add_argument("recursive", choices=("yes", "no"))
        command.add_argument("user")
        command.add_argument("permissions")
        command.add_argument("--snapshot", default="")

    for name in ("verify-access", "verify-default"):
        command = commands.add_parser(name)
        command.add_argument("folder")
        if name == "verify-access":
            command.add_argument("recursive", choices=("yes", "no"))
        command.add_argument("user")
        command.add_argument("permissions")

    for name in ("quiesce", "release"):
        command = commands.add_parser(name)
        command.add_argument("user")
        command.add_argument("marker")

    repair = commands.add_parser("repair")
    repair.add_argument("folder")
    repair.add_argument("recursive", choices=("yes", "no"))
    repair.add_argument("user")
    repair.add_argument("--audit", default="")
    repair.add_argument("--dry-run", action="store_true", dest="dry_run")
    return top


RECOVERY = {
    "restore": "the account %s may be locked and expired until this finishes. fix the cause above (for a folder it "
               "names that is too deep or cannot be read, remove it with rm -r), then run the same uninstall, rollback "
               "or repair command again: it continues where it stopped, and uninstall removes the account at the end.",
    "grant-access": "the account %s stays locked and expired until a run finishes. fix the cause above, then run the "
                    "same install or rollback command again: it finishes the grant and gives the account back.",
    "grant-default": "the account %s stays locked and expired until a run finishes. fix the cause above, then run the "
                     "same install or rollback command again: it finishes the grant and gives the account back.",
    "record": "the account %s stays locked and expired until a run finishes. fix the cause above, then run the same "
              "install or rollback command again: it records the folder and gives the account back.",
}


def raise_descriptor_limit():
    """a tree is walked with a bounded number of descriptors, but raise the soft limit anyway where allowed."""
    try:
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        if soft != hard:
            resource.setrlimit(resource.RLIMIT_NOFILE, (hard, hard))
    except (ValueError, OSError):
        pass


def main(argv):
    raise_descriptor_limit()
    try:
        arguments = parser().parse_args(argv)
    except SystemExit as stop:
        return EXIT_USAGE if stop.code else 0
    if arguments.command == "repair":
        arguments.snapshot = ""
        arguments.command = "restore"
    command = arguments.command
    try:
        status = {"check": command_check, "record": command_record, "restore": command_restore,
                  "status": command_status, "grant-access": command_grant_access,
                  "grant-default": command_grant_default, "quiesce": command_quiesce,
                  "release": command_release, "verify-access": command_verify_access,
                  "verify-default": command_verify_default}[command](arguments)
    except (OSError, Failure, subprocess.CalledProcessError) as error:
        say("error: %s" % error)
        status = EXIT_FAILED
    except Exception as error:  # nothing leaves here as a traceback: the person needs to know what to do next
        say("error: unexpected %s: %s" % (type(error).__name__, error))
        status = EXIT_FAILED
    if status == EXIT_FAILED and command in RECOVERY:
        say("recovery: " + RECOVERY[command] % getattr(arguments, "user", "agent"))
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
