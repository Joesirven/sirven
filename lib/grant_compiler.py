#!/usr/bin/env python3
"""grant compiler: turns a level plus a list of paths into access control list commands.

standard library python, like the other python under lib/. everything it prints is
deterministic: paths are normalized, deduplicated, and sorted, so golden tests can pin the
output byte for byte.

subcommands

  validate LEVEL_FILE...
      check that each level file keeps the hard rules (nothing widens itself, observer is
      read only, friend invites always expire). with several files, also check that exactly
      one level is the default for friend invites.

  describe --level FILE
      print key=value lines that install.sh reads (level, summary, write_allowed, ...).

  compile --level FILE --os linux|macos --user NAME [--prefix PATH] [--with-undo] --path PATH...
      print a plan fragment that grants the level on each path. with --with-undo, every line
      also carries the step that reverses it, for the install record uninstall.sh reads.

  revoke --level FILE --os linux|macos --user NAME [--prefix PATH] --path PATH...
  revoke --level FILE --os linux|macos --user NAME [--prefix PATH] --record GRANT_FILE
      print a plan fragment that removes what compile granted. with --record, the level and
      paths come from the grant record, and the level file is looked up next to --level.

  record --level FILE --user NAME --path PATH...
      print the grant record as JSON.

  show --record GRANT_FILE
      print a grant record as key=value lines, one path= line per path.

  last-grant --audit LOG --user NAME
      print the most recent grant entry for NAME in the audit log as key=value lines, with
      path= and previous_path= lines. prints nothing when there is none.

plan fragment format: lines starting with '#' are comments. every other line is one step,
three fields separated by a tab: title, check, command. the check is a read-only shell
command that exits 0 when the step is already done. the command applies the step. with
--with-undo, three more fields follow: the undo title, check, and command.
"""

import argparse
import json
import posixpath
import re
import shlex
import sys

LEVEL_NAMES = ("observer", "builder", "operator")
REQUIRED_DENIED = (
    "root",
    "sudo",
    "edit_own_policy",
    "edit_audit_log",
    "touch_kill_switch",
    "grant_further_access",
)
MACOS_WRITE_RIGHTS = (
    "write",
    "append",
    "add_file",
    "add_subdirectory",
    "delete",
    "delete_child",
    "writeattr",
    "writeextattr",
    "writesecurity",
    "chown",
)


class Refused(Exception):
    pass


def load_level(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except OSError as error:
        raise Refused("cannot read level file %s: %s" % (path, error.strerror))
    except ValueError as error:
        raise Refused("level file %s is not valid JSON: %s" % (path, error))


def level_problems(level):
    """return a list of rule violations for one level. empty means the level is fine."""
    problems = []
    name = level.get("level")
    if name not in LEVEL_NAMES:
        problems.append("level name must be one of %s, got %r" % (", ".join(LEVEL_NAMES), name))
    for key in ("summary", "write_allowed", "capabilities", "access_control", "paths", "expiry", "audit", "widening"):
        if key not in level:
            problems.append("missing key %r" % key)
    if problems:
        return problems

    widening = level["widening"]
    for key in ("can_grant", "can_edit_own_policy", "can_edit_audit_log", "can_touch_kill_switch", "root_or_sudo"):
        if widening.get(key) is not False:
            problems.append("widening.%s must be false: nothing widens itself" % key)

    denied = level["capabilities"].get("denied", [])
    for capability in REQUIRED_DENIED:
        if capability not in denied:
            problems.append("capabilities.denied must include %r" % capability)
    allowed = level["capabilities"].get("allowed", [])
    for capability in allowed:
        if capability in denied:
            problems.append("capability %r is both allowed and denied" % capability)

    write_allowed = level["write_allowed"]
    if name == "observer" and write_allowed is not False:
        problems.append("observer must be read only (write_allowed false)")
    linux = level["access_control"].get("linux", {})
    macos = level["access_control"].get("macos", {})
    if not write_allowed:
        if "w" in linux.get("grant", ""):
            problems.append("write_allowed is false but the linux grant includes write")
        rights = rights_list(macos.get("directories", "")) + rights_list(macos.get("files", ""))
        for right in rights:
            if right in MACOS_WRITE_RIGHTS:
                problems.append("write_allowed is false but the macos grant includes %r" % right)
    if linux.get("traverse") != "x":
        problems.append("access_control.linux.traverse must be exactly 'x'")
    if macos.get("traverse") != "search":
        problems.append("access_control.macos.traverse must be exactly 'search'")

    paths = level["paths"]
    if paths.get("default_grants"):
        problems.append("paths.default_grants must be empty: every path is granted explicitly")
    if paths.get("require_explicit_paths") is not True:
        problems.append("paths.require_explicit_paths must be true")
    if paths.get("deny_home_root") is not True:
        problems.append("paths.deny_home_root must be true")

    invite = level["expiry"].get("friend_invite", {})
    if invite.get("required") is not True:
        problems.append("expiry.friend_invite.required must be true: friend invites always expire")
    if invite.get("allowed"):
        default_days = invite.get("default_days", 0)
        maximum_days = invite.get("maximum_days", 0)
        if not (0 < default_days <= maximum_days):
            problems.append("friend invite expiry needs 0 < default_days <= maximum_days")
    if invite.get("default_level") and name != "observer":
        problems.append("only observer can be the default level for friend invites")

    audit = level["audit"]
    for key in ("session_start_and_end", "every_command"):
        if audit.get(key) is not True:
            problems.append("audit.%s must be true" % key)
    for key in ("agent_can_read_log", "agent_can_write_log"):
        if audit.get(key) is not False:
            problems.append("audit.%s must be false" % key)
    return problems


def rights_list(text):
    return [part for part in text.split(",") if part]


def checked_level(path):
    level = load_level(path)
    problems = level_problems(level)
    if problems:
        raise Refused("level file %s breaks the rules:\n  %s" % (path, "\n  ".join(problems)))
    return level


def normalize_path(raw):
    if not raw.startswith("/"):
        raise Refused("path %r must be absolute" % raw)
    parts = raw.split("/")
    if "." in parts or ".." in parts:
        raise Refused("path %r must not contain '.' or '..'" % raw)
    if "\n" in raw or "\t" in raw:
        raise Refused("path %r must not contain tabs or newlines" % raw)
    return posixpath.normpath(raw).replace("//", "/")


def within(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def policy_refusal(level, path, target_os, package):
    """return a reason string when the level's path policy refuses this path, else None."""
    policy = level["paths"]
    if path in policy.get("deny_exact", []):
        return "%s is too broad to grant" % path
    own = ["/etc/" + package, "/var/lib/" + package, "/var/log/" + package]
    for root in own + policy.get("deny_within", []):
        if within(path, root):
            if root in own:
                return "%s belongs to the package itself (policy, state, or audit log)" % path
            return "%s is inside %s, which is never granted" % (path, root)
    parts = [part for part in path.split("/") if part]
    for denied in policy.get("deny_components", []):
        denied_parts = denied.split("/")
        for start in range(len(parts) - len(denied_parts) + 1):
            if parts[start:start + len(denied_parts)] == denied_parts:
                return "%s touches %s, which holds keys or credentials" % (path, denied)
    if policy.get("deny_home_root") and len(parts) == 2 and parts[0] in ("home", "Users"):
        return "%s is a whole home directory; grant a project folder inside it" % path
    if target_os == "macos" and len(parts) >= 3 and parts[0] == "Users":
        if parts[2] in policy.get("macos_privacy_folders", []):
            return ("%s is inside a macos privacy folder (%s) that a service user cannot be "
                    "approved for; move the project elsewhere" % (path, parts[2]))
    return None


def granted_paths(level, raw_paths, target_os, package):
    if not raw_paths:
        raise Refused("at least one --path is required")
    paths = sorted(set(normalize_path(raw) for raw in raw_paths))
    for path in paths:
        reason = policy_refusal(level, path, target_os, package)
        if reason:
            raise Refused(reason)
    return paths


def traverse_parents(paths):
    """parents that need search permission so the service user can reach each path.

    a parent that is itself granted, or sits inside a granted path, is left alone so a
    traverse entry never downgrades a grant.
    """
    parents = set()
    for path in paths:
        current = posixpath.dirname(path)
        while current != "/":
            parents.add(current)
            current = posixpath.dirname(current)
    return sorted(parent for parent in parents if not any(within(parent, path) for path in paths))


def linux_entry(permissions):
    """what getfacl shows for a directory after setfacl with these permissions."""
    return "".join(letter if letter.lower() in permissions.lower() else "-" for letter in "rwx")


def fragment_line(title, check, command, undo=None):
    fields = [title, check, command]
    if undo:
        fields.extend(undo)
    return "\t".join(fields)


# each removal returns (title, check, command). revoke prints them as steps, and compile
# attaches them as the undo of the line they reverse, so both always agree.

def linux_traverse_removal(user, target, parent):
    return ("stop %s passing through %s" % (user, parent),
            "! getfacl --absolute-names --omit-header %s 2>/dev/null | grep -q '^user:%s:'" % (target, user),
            "setfacl -x u:%s %s" % (user, target))


def linux_grant_removal(user, target, path):
    return ("remove %s from %s and everything inside" % (user, path),
            "! getfacl --absolute-names --omit-header %s 2>/dev/null | grep -q '^user:%s:'" % (target, user),
            "setfacl -R -P -x u:%s %s" % (user, target))


def linux_default_removal(user, target, path):
    return ("stop new files in %s inheriting %s" % (path, user),
            "! getfacl --absolute-names --omit-header %s 2>/dev/null | grep -q '^default:user:%s:'" % (target, user),
            "setfacl -R -P -d -x u:%s %s" % (user, target))


def macos_traverse_removal(rights, user, target, parent):
    return ("stop %s passing through %s" % (user, parent),
            "! /bin/ls -lde %s 2>/dev/null | grep -q 'user:%s allow search'" % (target, user),
            "/bin/chmod -a %s %s" % (shlex.quote("%s allow %s" % (user, rights["traverse"])), target))


def macos_files_removal(rights, user, target, path):
    return ("remove %s file rights in %s" % (user, path),
            "! /bin/ls -lde %s 2>/dev/null | grep -q 'user:%s allow'" % (target, user),
            "/usr/bin/find %s -type f -exec /bin/chmod -a %s {} +"
            % (target, shlex.quote("%s allow %s" % (user, rights["files"]))))


def macos_folders_removal(rights, user, target, path):
    return ("remove %s folder rights on %s" % (user, path),
            "! /bin/ls -lde %s 2>/dev/null | grep -q 'user:%s allow'" % (target, user),
            "/usr/bin/find %s -type d -exec /bin/chmod -a %s {} +"
            % (target, shlex.quote("%s allow %s" % (user, rights["directories"]))))


def compile_linux(level, user, prefix, paths, with_undo=False):
    grant = level["access_control"]["linux"]["grant"]
    traverse = level["access_control"]["linux"]["traverse"]
    entry = linux_entry(grant)
    lines = []
    for parent in traverse_parents(paths):
        target = shlex.quote(prefix + parent)
        lines.append(fragment_line(
            "let %s pass through %s" % (user, parent),
            "getfacl --absolute-names --omit-header %s 2>/dev/null | grep -q '^user:%s:..x$'" % (target, user),
            "setfacl -m u:%s:%s %s" % (user, traverse, target),
            with_undo and linux_traverse_removal(user, target, parent)))
    for path in paths:
        target = shlex.quote(prefix + path)
        lines.append(fragment_line(
            "grant %s %s on %s and everything inside" % (user, grant, path),
            "getfacl --absolute-names --omit-header %s 2>/dev/null | grep -qx 'user:%s:%s'" % (target, user, entry),
            "setfacl -R -P -m u:%s:%s %s" % (user, grant, target),
            with_undo and linux_grant_removal(user, target, path)))
        lines.append(fragment_line(
            "make new files in %s inherit the grant" % path,
            "getfacl --absolute-names --omit-header %s 2>/dev/null | grep -qx 'default:user:%s:%s'" % (target, user, entry),
            "setfacl -R -P -d -m u:%s:%s %s" % (user, grant, target),
            with_undo and linux_default_removal(user, target, path)))
    return lines


def compile_macos(level, user, prefix, paths, with_undo=False):
    rights = level["access_control"]["macos"]
    lines = []
    for parent in traverse_parents(paths):
        target = shlex.quote(prefix + parent)
        lines.append(fragment_line(
            "let %s pass through %s" % (user, parent),
            "/bin/ls -lde %s 2>/dev/null | grep -q 'user:%s allow search'" % (target, user),
            "/bin/chmod +a %s %s" % (shlex.quote("%s allow %s" % (user, rights["traverse"])), target),
            with_undo and macos_traverse_removal(rights, user, target, parent)))
    for path in paths:
        target = shlex.quote(prefix + path)
        marker = "/bin/ls -lde %s 2>/dev/null | grep -q 'user:%s allow list'" % (target, user)
        lines.append(fragment_line(
            "grant %s file rights on files in %s" % (user, path),
            marker,
            "/usr/bin/find %s -type f -exec /bin/chmod +a %s {} +"
            % (target, shlex.quote("%s allow %s" % (user, rights["files"]))),
            with_undo and macos_files_removal(rights, user, target, path)))
        lines.append(fragment_line(
            "grant %s folder rights on %s and folders inside, inherited by new files" % (user, path),
            marker,
            "/usr/bin/find %s -type d -exec /bin/chmod +a %s {} +"
            % (target, shlex.quote("%s allow %s" % (user, rights["directories"]))),
            with_undo and macos_folders_removal(rights, user, target, path)))
    return lines


def revoke_linux(level, user, prefix, paths, with_undo=False):
    lines = []
    for path in paths:
        target = shlex.quote(prefix + path)
        lines.append(fragment_line(*linux_grant_removal(user, target, path)))
        lines.append(fragment_line(*linux_default_removal(user, target, path)))
    for parent in traverse_parents(paths):
        lines.append(fragment_line(*linux_traverse_removal(user, shlex.quote(prefix + parent), parent)))
    return lines


def revoke_macos(level, user, prefix, paths, with_undo=False):
    rights = level["access_control"]["macos"]
    lines = []
    for path in paths:
        target = shlex.quote(prefix + path)
        lines.append(fragment_line(*macos_files_removal(rights, user, target, path)))
        lines.append(fragment_line(*macos_folders_removal(rights, user, target, path)))
    for parent in traverse_parents(paths):
        lines.append(fragment_line(*macos_traverse_removal(rights, user, shlex.quote(prefix + parent), parent)))
    return lines


def from_record(arguments):
    """for revoke --record: take the level and paths from a grant record written at install."""
    try:
        with open(arguments.record, encoding="utf-8") as handle:
            grant = json.load(handle)
    except (OSError, ValueError) as error:
        raise Refused("cannot read grant record %s: %s" % (arguments.record, error))
    if grant.get("level") not in LEVEL_NAMES or not isinstance(grant.get("paths"), list):
        raise Refused("grant record %s has no valid level and paths" % arguments.record)
    level_file = posixpath.join(posixpath.dirname(arguments.level), grant["level"] + ".json")
    return checked_level(level_file), grant["paths"]


def fragment(kind, arguments):
    prefix = (arguments.prefix or "").rstrip("/")
    if prefix and not prefix.startswith("/"):
        raise Refused("--prefix must be absolute")
    if getattr(arguments, "record", None):
        level, raw_paths = from_record(arguments)
    else:
        level, raw_paths = checked_level(arguments.level), arguments.path
    paths = granted_paths(level, raw_paths, arguments.os, arguments.package)
    builders = {
        ("compile", "linux"): compile_linux,
        ("compile", "macos"): compile_macos,
        ("revoke", "linux"): revoke_linux,
        ("revoke", "macos"): revoke_macos,
    }
    with_undo = getattr(arguments, "with_undo", False)
    lines = builders[(kind, arguments.os)](level, arguments.user, prefix, paths, with_undo)
    header = [
        "# %s %s for %s on %s" % (kind, level["level"], arguments.user, arguments.os),
        "# paths: %s" % " ".join(paths),
    ]
    return "\n".join(header + lines) + "\n"


def describe(arguments):
    level = checked_level(arguments.level)
    invite = level["expiry"]["friend_invite"]
    pairs = [
        ("level", level["level"]),
        ("summary", level["summary"]),
        ("write_allowed", "true" if level["write_allowed"] else "false"),
        ("friend_invite_allowed", "true" if invite.get("allowed") else "false"),
        ("friend_invite_default_level", "true" if invite.get("default_level") else "false"),
        ("friend_invite_default_days", str(invite.get("default_days", 0))),
        ("friend_invite_maximum_days", str(invite.get("maximum_days", 0))),
        ("audit_retention_days", str(level["audit"].get("retention_days", 0))),
    ]
    return "".join("%s=%s\n" % pair for pair in pairs)


def record(arguments):
    level = checked_level(arguments.level)
    paths = granted_paths(level, arguments.path, arguments.os, arguments.package)
    grant = {
        "schema_version": 1,
        "principal": "owner-agent",
        "user": arguments.user,
        "level": level["level"],
        "paths": paths,
        "write_allowed": level["write_allowed"],
        "expires": None,
        "can_grant": False,
    }
    return json.dumps(grant, indent=2, sort_keys=True) + "\n"


def show(arguments):
    try:
        with open(arguments.record, encoding="utf-8") as handle:
            grant = json.load(handle)
    except (OSError, ValueError) as error:
        raise Refused("cannot read grant record %s: %s" % (arguments.record, error))
    if grant.get("level") not in LEVEL_NAMES or not isinstance(grant.get("paths"), list):
        raise Refused("grant record %s has no valid level and paths" % arguments.record)
    pairs = [
        ("level", grant["level"]),
        ("user", grant.get("user", "")),
        ("principal", grant.get("principal", "")),
        ("write_allowed", "true" if grant.get("write_allowed") else "false"),
        ("expires", grant.get("expires") or "never"),
        ("can_grant", "true" if grant.get("can_grant") else "false"),
    ]
    pairs.extend(("path", path) for path in grant["paths"])
    return "".join("%s=%s\n" % (key, one_line(value)) for key, value in pairs)


def one_line(value):
    return str(value).replace("\n", " ").replace("\r", " ")


def last_grant(arguments):
    """the most recent grant entry for the user. lines that are not JSON objects are skipped."""
    found = None
    skipped = 0
    try:
        with open(arguments.audit, encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    skipped += 1
                    continue
                if isinstance(entry, dict) and entry.get("event") == "grant" and entry.get("user") == arguments.user:
                    found = entry
    except OSError as error:
        raise Refused("cannot read audit log %s: %s" % (arguments.audit, error.strerror))
    if found is None:
        return "skipped_lines=%d\n" % skipped if skipped else ""
    pairs = [
        ("time", found.get("time", "")),
        ("reason", found.get("reason", "")),
        ("level", found.get("level") or "none"),
        ("previous_level", found.get("previous_level") or "none"),
    ]
    for key, name in (("paths", "path"), ("previous_paths", "previous_path")):
        values = found.get(key) or []
        if not isinstance(values, list):
            raise Refused("the last grant entry in %s has a %s that is not a list" % (arguments.audit, key))
        pairs.extend((name, value) for value in values)
    if skipped:
        pairs.append(("skipped_lines", skipped))
    return "".join("%s=%s\n" % (key, one_line(value)) for key, value in pairs)


def validate(arguments):
    defaults = []
    output = []
    for path in arguments.levels:
        level = checked_level(path)
        output.append("ok %s (%s)" % (level["level"], path))
        if level["expiry"]["friend_invite"].get("default_level"):
            defaults.append(level["level"])
    if len(arguments.levels) > 1 and defaults != ["observer"]:
        raise Refused("exactly one level, observer, must be the friend invite default; got %s" % (defaults or "none"))
    return "\n".join(output) + "\n"


def parser():
    top = argparse.ArgumentParser(prog="grant_compiler.py", description="grant compiler for access control lists")
    commands = top.add_subparsers(dest="command")
    commands.required = True

    check = commands.add_parser("validate")
    check.add_argument("levels", nargs="+")

    show = commands.add_parser("describe")
    show.add_argument("--level", required=True)

    for name in ("compile", "revoke", "record"):
        command = commands.add_parser(name)
        command.add_argument("--level", required=True)
        command.add_argument("--user", default="agent")
        command.add_argument("--os", choices=("linux", "macos"), default="linux")
        command.add_argument("--prefix", default="")
        command.add_argument("--package", default="sirven")
        command.add_argument("--path", action="append", default=[])
        if name == "revoke":
            command.add_argument("--record", default="")
        if name == "compile":
            command.add_argument("--with-undo", action="store_true")

    shown = commands.add_parser("show")
    shown.add_argument("--record", required=True)

    last = commands.add_parser("last-grant")
    last.add_argument("--audit", required=True)
    last.add_argument("--user", default="agent")
    return top


def main(argv):
    arguments = parser().parse_args(argv)
    try:
        if not re.match(r"^[a-z_][a-z0-9_-]{0,31}$", getattr(arguments, "user", "agent")):
            raise Refused("user name %r is not a plain lowercase account name" % arguments.user)
        if arguments.command == "validate":
            sys.stdout.write(validate(arguments))
        elif arguments.command == "describe":
            sys.stdout.write(describe(arguments))
        elif arguments.command == "record":
            sys.stdout.write(record(arguments))
        elif arguments.command == "show":
            sys.stdout.write(show(arguments))
        elif arguments.command == "last-grant":
            sys.stdout.write(last_grant(arguments))
        else:
            sys.stdout.write(fragment(arguments.command, arguments))
    except Refused as error:
        sys.stderr.write("grant compiler: refused: %s\n" % error)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
