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

  folders --level FILE --os linux|macos --user NAME --path PATH...
      print the folders a grant changes, one per line: "tree<TAB>PATH" for each granted path and
      "alone<TAB>PATH" for each pass-through parent. install.sh hands them to the check that refuses
      lists the grant would widen.

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
import hashlib
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
# attaches them as the undo of the line they reverse, so both always agree (on macos both are the same sweep).

def linux_snapshot(state_dir, path):
    """where the access control lists of one path are recorded before a grant (root only)."""
    digest = hashlib.sha256(path.encode("utf-8")).hexdigest()[:16]
    return "%s/access-lists/%s.txt" % (state_dir, digest)


def linux_helper(package):
    """the helper that records and restores the lists, in the pinned copy the install keeps."""
    return "/var/lib/%s/package/lib/access_control_snapshot.sh" % package


def linux_audit_log(package):
    return "/var/log/%s/audit.jsonl" % package


def linux_recursive_word(recursive):
    return "yes" if recursive else "no"


def linux_restore_removal(user, target, snapshot, helper, recursive, title, audit):
    """put the lists back the way the snapshot recorded them, removing only what the grant added.

    the check is the state of the folder, not whether the snapshot file exists: the step is done only
    when the snapshot is gone and no entry of the agent is left. a missing snapshot is not done; the
    helper still removes the grant's entries and says loudly that earlier lists could not be restored.
    """
    word = linux_recursive_word(recursive)
    return (title,
            "bash %s status %s %s %s %s" % (helper, snapshot, target, word, user),
            "bash %s restore %s %s %s %s --audit %s" % (helper, snapshot, target, word, user, audit))


def linux_stop_agent_removal(user):
    """runs before any list is put back: expire the account and end its processes, so nothing the agent
    runs can change the folders while the lists are restored. the account itself is removed later."""
    return ("end every process of %s and expire its account, so nothing changes the granted folders while the lists are put back" % user,
            "false",
            "{ usermod --expiredate 1 --lock %s || true; } && { pkill -KILL -u %s || true; }" % (user, user))


def macos_helper(package):
    """the helper that checks and sweeps the lists, in the pinned copy the install keeps."""
    return "/var/lib/%s/package/lib/access_control_macos.sh" % package


def macos_sweep_removal(user, target, path, tree, title, prefix, package):
    """the undo of a macos grant: remove every entry of the agent from the path and, for a granted folder,
    everything inside it, then check that none is left. not a subtraction of the rights the grant added: see the
    header of lib/access_control_macos.py for why that cannot restore a list exactly. revoke uses it too."""
    helper = shlex.quote(prefix + macos_helper(package))
    word = linux_recursive_word(tree)
    return (title,
            "bash %s status %s %s %s" % (helper, user, word, target),
            "bash %s sweep %s %s %s" % (helper, user, word, target))


def compile_linux(level, user, prefix, paths, with_undo=False, package="sirven"):
    grant = level["access_control"]["linux"]["grant"]
    traverse = level["access_control"]["linux"]["traverse"]
    entry = linux_entry(grant)
    state_dir = "/var/lib/%s" % package
    helper = linux_helper(package)
    audit = shlex.quote(prefix + linux_audit_log(package))
    parents = traverse_parents(paths)
    # every snapshot comes before the first change, so a path nested in a granted path is recorded
    # before its parent's grant reaches it. a traverse folder is recorded without its contents.
    targets = [(parent, False) for parent in parents] + [(path, True) for path in paths]
    records = []
    if with_undo:
        for path, recursive in targets:
            target = shlex.quote(prefix + path)
            snapshot = shlex.quote(prefix + linux_snapshot(state_dir, path))
            word = linux_recursive_word(recursive)
            undo = linux_restore_removal(
                user, target, snapshot, shlex.quote(prefix + helper), recursive,
                "put back the access control lists of %s as they were before the grant, removing only what the grant added" % path,
                audit)
            records.append(fragment_line(
                "record the access control lists of %s before the grant" % path,
                "[ -s %s ]" % snapshot,
                "bash %s record %s %s %s %s" % (shlex.quote(prefix + helper), snapshot, target, word, user),
                undo))
    # the grants are done by the helper, by file descriptor, never following a link (see
    # lib/access_control_snapshot.py). each names its snapshot, so the folder it changes is checked
    # to be the one that was recorded. the agent's account is ended and locked around them.
    helper_word = shlex.quote(prefix + helper)
    marker = shlex.quote(prefix + "%s/agent-quiesce.json" % state_dir)
    grants = []
    for parent in parents:
        target = shlex.quote(prefix + parent)
        snapshot = " --snapshot " + shlex.quote(prefix + linux_snapshot(state_dir, parent)) if with_undo else ""
        grants.append(fragment_line(
            "let %s pass through %s" % (user, parent),
            "getfacl --absolute-names --omit-header %s 2>/dev/null | grep -q '^user:%s:..x$'" % (target, user),
            "bash %s grant-access %s no %s %s%s" % (helper_word, target, user, traverse, snapshot)))
    for path in paths:
        target = shlex.quote(prefix + path)
        snapshot = " --snapshot " + shlex.quote(prefix + linux_snapshot(state_dir, path)) if with_undo else ""
        # the checks read the whole tree (a grant that stopped partway is not done), by descriptor like the grant
        grants.append(fragment_line(
            "grant %s %s on %s and everything inside" % (user, grant, path),
            "bash %s verify-access %s yes %s %s" % (helper_word, target, user, grant),
            "bash %s grant-access %s yes %s %s%s" % (helper_word, target, user, grant, snapshot)))
        # the default list gives group and other nothing, whatever the owner's umask. the agent and
        # the folder owner get the grant on new files, by account number, so an owner with no account
        # name (a deleted account, a mounted volume) works, and root and the agent are not added as the owner.
        grants.append(fragment_line(
            "make new files in %s inherit the grant, with group and other kept out" % path,
            "bash %s verify-default %s %s %s" % (helper_word, target, user, grant),
            "bash %s grant-default %s %s %s%s" % (helper_word, target, user, grant, snapshot),
            linux_stop_agent_removal(user) if with_undo else None))
    # the account is stopped only when a grant step has work to do: a re-run that finds every grant in
    # place leaves a running agent alone. a rollback marks its steps as always to do, so it always stops.
    everything_in_place = " && ".join("{ %s; }" % line.split("\t")[1] for line in grants)
    lines = []
    lines.append(fragment_line(
        "end every process of %s and lock its account while the access changes" % user,
        everything_in_place,
        "bash %s quiesce %s %s" % (helper_word, user, marker)))
    lines.extend(records)
    lines.extend(grants)
    lines.append(fragment_line(
        "give %s its account back" % user,
        # also not done while the marker is there: a run that stopped before this step left the account locked
        "[ ! -e %s ] && %s" % (marker, everything_in_place),
        "bash %s release %s %s" % (helper_word, user, marker)))
    return lines


def compile_macos(level, user, prefix, paths, with_undo=False, package="sirven"):
    rights = level["access_control"]["macos"]
    lines = []

    def undo(target, path, tree, title):
        return with_undo and macos_sweep_removal(user, target, path, tree, title, prefix, package)

    for parent in traverse_parents(paths):
        target = shlex.quote(prefix + parent)
        lines.append(fragment_line(
            "let %s pass through %s" % (user, parent),
            "/bin/ls -lde %s 2>/dev/null | grep -q 'user:%s allow search'" % (target, user),
            "/bin/chmod -h +a %s %s" % (shlex.quote("%s allow %s" % (user, rights["traverse"])), target),
            undo(target, parent, False, "stop %s passing through %s" % (user, parent))))
    for path in paths:
        target = shlex.quote(prefix + path)
        marker = "/bin/ls -lde %s 2>/dev/null | grep -q 'user:%s allow list'" % (target, user)
        lines.append(fragment_line(
            "grant %s file rights on files in %s" % (user, path),
            marker,
            "/usr/bin/find -P %s -type f -exec /bin/chmod -h +a %s {} +"
            % (target, shlex.quote("%s allow %s" % (user, rights["files"]))),
            undo(target, path, True, "remove every entry of %s from %s and everything inside it" % (user, path))))
        lines.append(fragment_line(
            "grant %s folder rights on %s and folders inside, inherited by new files" % (user, path),
            marker,
            "/usr/bin/find -P %s -type d -exec /bin/chmod -h +a %s {} +"
            % (target, shlex.quote("%s allow %s" % (user, rights["directories"]))),
            undo(target, path, True, "remove every entry of %s from %s and everything inside it" % (user, path))))
    return lines


def revoke_linux(level, user, prefix, paths, with_undo=False, package="sirven"):
    state_dir = "/var/lib/%s" % package
    helper = shlex.quote(prefix + linux_helper(package))
    audit = shlex.quote(prefix + linux_audit_log(package))
    lines = []
    for path in paths:
        target = shlex.quote(prefix + path)
        snapshot = shlex.quote(prefix + linux_snapshot(state_dir, path))
        lines.append(fragment_line(*linux_restore_removal(
            user, target, snapshot, helper, True,
            "remove %s from %s and put back the access control lists it had" % (user, path), audit)))
    for parent in traverse_parents(paths):
        target = shlex.quote(prefix + parent)
        snapshot = shlex.quote(prefix + linux_snapshot(state_dir, parent))
        lines.append(fragment_line(*linux_restore_removal(
            user, target, snapshot, helper, False,
            "stop %s passing through %s and put back its access control list" % (user, parent), audit)))
    return lines


def revoke_macos(level, user, prefix, paths, with_undo=False, package="sirven"):
    """revoke on macos is the same sweep the undo of a grant is, so revoke and uninstall agree and both leave no
    entry that names the account (see macos_sweep_removal for why a subtraction cannot). the order is as it
    was: each granted path with everything inside it, then the pass-through parents on their own."""
    lines = []
    for path in paths:
        lines.append(fragment_line(*macos_sweep_removal(
            user, shlex.quote(prefix + path), path, True,
            "remove every entry of %s from %s and everything inside it" % (user, path), prefix, package)))
    for parent in traverse_parents(paths):
        lines.append(fragment_line(*macos_sweep_removal(
            user, shlex.quote(prefix + parent), parent, False,
            "stop %s passing through %s" % (user, parent), prefix, package)))
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
    lines = builders[(kind, arguments.os)](level, arguments.user, prefix, paths, with_undo, arguments.package)
    header = [
        "# %s %s for %s on %s" % (kind, level["level"], arguments.user, arguments.os),
        "# paths: %s" % " ".join(paths),
    ]
    return "\n".join(header + lines) + "\n"


def folders(arguments):
    """the folders a linux grant changes, for the check that refuses lists it would widen: a tree line
    for each granted path (everything inside is changed) and an alone line for each pass-through parent."""
    level = checked_level(arguments.level)
    paths = granted_paths(level, arguments.path, arguments.os, arguments.package)
    lines = ["tree\t%s" % path for path in paths] + ["alone\t%s" % parent for parent in traverse_parents(paths)]
    return "\n".join(lines) + "\n"


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

    for name in ("compile", "revoke", "record", "folders"):
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
        elif arguments.command == "folders":
            sys.stdout.write(folders(arguments))
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
