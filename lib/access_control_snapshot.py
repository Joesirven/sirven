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
import base64
import datetime
import errno
import json
import os
import pwd
import stat
import struct
import subprocess
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
    """call visit(handle, info, path, is_folder) for the folder and everything below it. the handle is an
    open descriptor, or for a pipe, device, or socket a /proc/self/fd path naming one. symbolic links are
    skipped; a path that cannot be opened is reported, not fatal."""
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
            elif stat.S_ISFIFO(before.st_mode) or stat.S_ISSOCK(before.st_mode) or stat.S_ISCHR(before.st_mode) \
                    or stat.S_ISBLK(before.st_mode):
                # the grant gave these entries too, but opening a pipe or a device could block or act. an
                # O_PATH descriptor only names the object, and /proc/self/fd/N reaches its attributes.
                descriptor = os.open(name, os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=folder_fd)
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
            elif stat.S_ISREG(opened.st_mode):
                visit(descriptor, opened, child, False)
            else:
                visit("/proc/self/fd/%d" % descriptor, opened, child, False)
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


def access_with_grant(current, mode, is_folder, agent, spec):
    """the access list after the agent gets the permissions. pure."""
    bits, conditional = parse_permissions(spec)
    entries = list(current) if current else mode_entries(mode)
    if conditional and (is_folder or any(perm & 1 for _, perm, _ in entries)):
        bits |= 1
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
    source = default if default else [entry for entry in (access or mode_entries(mode)) if entry[0] in (USER_OBJ, GROUP_OBJ, OTHER)]
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
            with open(arguments.snapshot, encoding="utf-8") as handle:
                context = json.load(handle)["context"]
        except (OSError, ValueError, KeyError) as error:
            raise Failure("no usable snapshot at %s (%s), so %s is not changed" % (arguments.snapshot, error, arguments.folder))
        if (context["dev"], context["ino"], context["resolved"]) != (info.st_dev, info.st_ino, resolved):
            raise Failure("%s is not the folder that was recorded before the grant; it was not changed" % arguments.folder)
    start(resolved, recursive, visit, errors)
    return agent, info


def finish_changes(errors):
    for path, reason in errors[:LISTED]:
        say("error: %s: %s" % (printable(path), reason))
    return EXIT_FAILED if errors else 0


def command_grant_access(arguments):
    recursive = arguments.recursive == "yes"
    errors = []

    def visit(handle, item, path, is_folder):
        try:
            current = read_list(handle, ACCESS)
            wanted = access_with_grant(current, stat.S_IMODE(item.st_mode), is_folder, agent, arguments.permissions)
            if wanted != current:
                os.setxattr(handle, ACCESS, build(wanted))
        except OSError as error:
            errors.append((path, error.strerror))

    agent = account_number(arguments.user)
    start_checked(arguments, recursive, visit, errors)
    return finish_changes(errors)


def command_grant_default(arguments):
    errors = []
    owner = []

    def visit(handle, item, path, is_folder):
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
            errors.append((path, error.strerror))

    agent = account_number(arguments.user)
    start_checked(arguments, True, visit, errors)
    return finish_changes(errors)


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
    subprocess.run(["pkill", "-KILL", "-u", arguments.user])
    return 0


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
        before = parse(base64.b64decode(recorded))
        again = [entry for entry in before if entry[0] == USER and entry[2] in (agent, owner)]
        kept = kept + again
        masks = [entry[1] for entry in before if entry[0] == MASK]
        if again and masks:
            kept = [(tag, perm & masks[0], number) if tag == MASK else (tag, perm, number) for tag, perm, number in kept]
    kept.sort(key=lambda e: (e[0], e[2] if e[0] in (USER, GROUP) else 0))
    if has_named(kept):
        return kept
    mask = next((perm for tag, perm, _ in kept if tag == MASK), 7)
    return [(tag, perm & mask if tag == GROUP_OBJ else perm, number) for tag, perm, number in kept if tag != MASK]


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
        os.setxattr(fd, DEFAULT, base64.b64decode(recorded))
    else:
        os.removexattr(fd, DEFAULT)
    changes.append(1)


def restore_folder(arguments):
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
    return EXIT_FAILED if errors else 0


def command_restore(arguments):
    status = restore_folder(arguments)
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

    for name in ("grant-access", "grant-default"):
        command = commands.add_parser(name)
        command.add_argument("folder")
        if name == "grant-access":
            command.add_argument("recursive", choices=("yes", "no"))
        command.add_argument("user")
        command.add_argument("permissions")
        command.add_argument("--snapshot", default="")

    for name in ("quiesce", "release"):
        command = commands.add_parser(name)
        command.add_argument("user")
        command.add_argument("marker")

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
        return {"check": command_check, "record": command_record, "restore": command_restore,
                "status": command_status, "grant-access": command_grant_access,
                "grant-default": command_grant_default, "quiesce": command_quiesce,
                "release": command_release}[arguments.command](arguments)
    except (OSError, Failure, subprocess.CalledProcessError) as error:
        say("error: %s" % error)
        return EXIT_FAILED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
