#!/usr/bin/env python3
"""access control macos: check, status, and sweep the access control list entries of the service user.

standard library python, started by lib/access_control_macos.sh. macos only (it reads lists with
/bin/ls -lde and changes them with /bin/chmod -h).

  check  USER [--allow-own-entries] --tree FOLDER... --alone FOLDER...
      read only. refuse (exit 3, the reasons on standard output) when a granted folder or a
      pass-through parent is missing, is not a folder, or is a symbolic link (find -P on a link grants
      nothing, and chmod -h would change the link, so the grant would silently do the wrong thing), or
      when anything in the granted trees, or a pass-through parent, already has an entry for USER.
      with --allow-own-entries only the link and folder checks apply: a second run of an install
      this package made finds its own earlier entries.
  status USER yes|no PATH
      read only. exit 0 when no entry for USER is left on PATH and, with yes, anywhere inside it.
  sweep  USER yes|no PATH
      remove every entry for USER from PATH and, with yes, from everything inside it, inherited
      entries included, highest index first. nothing is followed: a link inside the tree is looked
      at and changed as a link. an item with no list is fine. nothing else in any list is touched.

why a sweep and not a subtraction of the rights the grant added: chmod +a merges rights into an
entry that is already there, and a file created inside a granted folder inherits an entry built from
the folder rights, so subtracting the file rights leaves a remainder behind, and fails on an item that
has no list. the service user is created by this install and holds no entry anywhere before the
grant (check), so every entry that names it was added by the grant, and sweeping them all puts every
list back exactly as it was. the mode bits are never touched: a macos list lives beside them.

names are listed with ls -b, which writes a newline in a file name as \\n, so no file name can look like a list
entry or a heading. a granted path that has become a link is refused, not followed.

entries are matched by the account name and, when the directory service answers, by its
GeneratedUID, which is how a list shows an account that was deleted. run the sweep before the account
is removed (uninstall reverses the account last).
"""

import os
import re
import subprocess
import sys

LS = "/bin/ls"
CHMOD = "/bin/chmod"
DSCL = "/usr/bin/dscl"
BATCH = 200
ENTRY = re.compile(r"^\s+(\d+): (user|group):(\S+) ")
HEADING = re.compile(r"^[-dlbcpsw?][-rwxsStT@+ ]")


def account_names(user):
    names = {user}
    try:
        result = subprocess.run([DSCL, ".", "-read", "/Users/" + user, "GeneratedUID"],
                                capture_output=True, text=True, check=False)
    except OSError:
        return names
    if result.returncode == 0:
        parts = result.stdout.split()
        if len(parts) == 2 and parts[0] == "GeneratedUID:":
            names.add(parts[1])
    return names


def walk(path, whole_tree, errors):
    """the path, then every item under it when whole_tree. nothing is followed."""
    items = [path]
    if not whole_tree:
        return items

    def remember(error):
        errors.append("cannot read %s: %s" % (error.filename, error.strerror))

    for directory, directories, files in os.walk(path, followlinks=False, onerror=remember):
        for name in directories + files:
            items.append(os.path.join(directory, name))
    return items


def parse_entries(lines, names):
    """the indexes of the entries in an ls -lde listing that name the account."""
    found = []
    for line in lines:
        match = ENTRY.match(line)
        if match and match.group(2) == "user" and match.group(3) in names:
            found.append(int(match.group(1)))
    return found


def list_one(path):
    result = subprocess.run([LS, "-ldeb", "--", path], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise OSError("cannot read the access list of %s: %s" % (path, result.stderr.strip()))
    return result.stdout.split("\n")[1:]


def matching_entries(paths, names):
    """path -> indexes of the entries naming the account, for the paths that have any. reads in
    batches in the order given (ls -f does not sort); a batch that does not come back as one
    heading per path is read one by one."""
    found = {}
    for start in range(0, len(paths), BATCH):
        chunk = paths[start:start + BATCH]
        result = subprocess.run([LS, "-ldefb", "--"] + chunk, capture_output=True, text=True, check=False)
        groups = []
        for line in result.stdout.split("\n"):
            if ENTRY.match(line):
                if groups:
                    groups[-1].append(line)
            elif HEADING.match(line):
                groups.append([])
                groups[-1].append(line)
        if result.returncode == 0 and len(groups) == len(chunk):
            for path, group in zip(chunk, groups):
                indexes = parse_entries(group[1:], names)
                if indexes:
                    found[path] = indexes
        else:
            for path in chunk:
                indexes = parse_entries(list_one(path), names)
                if indexes:
                    found[path] = indexes
    return found


def sweep_path(path, indexes):
    for index in sorted(indexes, reverse=True):
        result = subprocess.run([CHMOD, "-h", "-a#", str(index), path],
                                capture_output=True, text=True, check=False)
        if result.returncode != 0:
            raise OSError("cannot remove entry %d from %s: %s" % (index, path, result.stderr.strip()))


def command_check(arguments):
    user, own, trees, alones = arguments
    problems = []
    names = account_names(user)
    for path in trees + alones:
        if os.path.islink(path):
            problems.append("%s is a symbolic link; grant the folder it points to" % path)
        elif not os.path.isdir(path):
            problems.append("%s is not a folder that exists" % path)
    if not problems and not own:
        errors = []
        for path in trees:
            for item, indexes in matching_entries(walk(path, True, errors), names).items():
                problems.append("%s already has an access list entry for %s" % (item, user))
        for path, indexes in matching_entries(alones, names).items():
            problems.append("%s already has an access list entry for %s" % (path, user))
        problems.extend(errors)
    for problem in problems:
        print(problem)
    return 3 if problems else 0


def command_status(user, tree, path):
    if os.path.islink(path):
        print("%s is a symbolic link now; it is not followed, so it is not swept" % path, file=sys.stderr)
        return 1
    errors = []
    names = account_names(user)
    left = matching_entries(walk(path, tree, errors), names) if os.path.lexists(path) else {}
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    for item in sorted(left):
        print("%s still has an entry for %s" % (item, user), file=sys.stderr)
    return 1 if left else 0


def command_sweep(user, tree, path):
    if os.path.islink(path):
        print("%s is a symbolic link now; it is not followed, so it is not swept" % path, file=sys.stderr)
        return 1
    if not os.path.lexists(path):
        return 0
    errors = []
    names = account_names(user)
    found = matching_entries(walk(path, tree, errors), names)
    for item in sorted(found):
        sweep_path(item, found[item])
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print("removed %d entries for %s from %d items under %s" % (sum(len(v) for v in found.values()), user, len(found), path))
    return 0


def usage():
    print(__doc__.split("\n\n")[0], file=sys.stderr)
    return 64


def main(argv):
    if len(argv) < 3:
        return usage()
    name, user, rest = argv[0], argv[1], argv[2:]
    try:
        if name == "check":
            own, trees, alones, mode = False, [], [], None
            for word in rest:
                if word == "--allow-own-entries":
                    own = True
                elif word == "--tree":
                    mode = trees
                elif word == "--alone":
                    mode = alones
                elif mode is not None:
                    mode.append(word)
                else:
                    return usage()
            return command_check((user, own, trees, alones))
        if name in ("status", "sweep") and len(rest) == 2 and rest[0] in ("yes", "no"):
            function = command_status if name == "status" else command_sweep
            return function(user, rest[0] == "yes", rest[1])
    except OSError as error:
        print("error: %s" % error, file=sys.stderr)
        return 1
    return usage()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
