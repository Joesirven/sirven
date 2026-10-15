# permissions

how the package decides what the agent can touch. the levels are data in `levels/*.json`, and
`lib/grant_compiler.py` turns a level plus a list of paths into access control list commands.
this document explains both. terms follow `docs/SCOPE.md`.

## levels

a level is a preset bundle of permissions. there are three, and the installer defaults to the
smallest one.

| | observer | builder | operator |
|---|---|---|---|
| reads granted paths | yes | yes | yes |
| writes granted paths | no | yes | yes |
| runs commands as the service user | yes | yes | yes |
| restarts services the owner lists | no | no | designed, not built |
| reads logs the owner lists | no | no | designed, not built |
| linux entry (`setfacl`) | `rX` | `rwX` | `rwX` |
| default level for friend invites | yes | no | no |
| friend invites allowed | yes, 7 days by default, 30 at most | yes, 3 days by default, 7 at most | no |
| root or `sudo` | never | never | never |

every level denies the same things, whatever else it allows: root, `sudo`, writing outside the
service user's home and its granted paths, restarting system services, changing the transport,
the SSH server, or any account, editing its own policy, editing the audit log, touching the kill
switch, and granting access to anyone else.

## what each level file holds

- `level`, `summary`, `write_allowed`
- `capabilities.allowed`, `capabilities.denied`, `capabilities.designed_not_built`
- `access_control.linux`: the `setfacl` permissions for the grant (`rX` or `rwX`) and for
  passing through parent folders (`x`)
- `access_control.macos`: the `chmod +a` rights for folders, for files, and for passing
  through parent folders (`search`)
- `paths`: the policy for which paths can be granted at all (below). `default_grants` is always
  empty: nothing is granted unless the owner names it.
- `expiry`: owner grants have no expiry; friend invites always do
- `audit`: install and grant changes are logged; session and command logging is planned, not built yet. the agent can never read or write the log
- `widening`: every field is `false`
- `owner_listed` (operator only): the services and logs the owner names for operator. both
  lists are empty and nothing reads them yet.

### field reference

every field, its meaning, and what enforces it today. "rule n" points at the list below.

| field | meaning | enforced by |
|---|---|---|
| `schema_version` | the level file format, `1` | read by nothing yet; bump it when a field changes meaning |
| `level` | `observer`, `builder`, or `operator`, the same as the file name | rule 9; a unit test checks the file name |
| `summary` | one line, shown in the plan under the access section | required key |
| `write_allowed` | whether any write right may appear in the entries | rule 2 |
| `capabilities.allowed` | words naming what the level permits | rule 8; documentation, nothing compiles from it |
| `capabilities.denied` | words naming what it never permits | rules 1 and 8 |
| `capabilities.designed_not_built` | allowed capabilities that compile to nothing today | documentation only |
| `access_control.linux.grant` | `setfacl` permissions on granted paths: `rX` or `rwX` | rule 2 |
| `access_control.linux.traverse` | permission on parent folders | rule 7: exactly `x` |
| `access_control.macos.directories`, `.files` | `chmod +a` rights, comma separated, for folders and for files | rule 2 |
| `access_control.macos.traverse` | right on parent folders | rule 7: exactly `search` |
| `paths.default_grants` | paths granted without being asked | rule 3: always empty |
| `paths.require_explicit_paths` | every path comes from `--path` | rule 3: always true |
| `paths.deny_exact` | paths refused only as themselves, being too broad | the path checks below |
| `paths.deny_within` | paths refused together with everything inside them | the path checks below |
| `paths.deny_components` | folder names refused anywhere in a path. an entry with a slash, like `.config/gh`, matches those folders in that order | the path checks below |
| `paths.deny_home_root` | refuse `/home/name` and `/Users/name` themselves | rule 3: always true |
| `paths.macos_privacy_folders` | folders right under a macos home that are refused | the path checks below, macos only |
| `expiry.owner_grant.required` | whether the owner's own grant must expire | `false` for every level; grant records carry `expires: null` |
| `expiry.friend_invite.allowed` | whether a friend's agent may get this level | rule 4 |
| `expiry.friend_invite.default_level` | the level an invite gets when none is named | rule 5: observer only |
| `expiry.friend_invite.required` | an invite must expire | rule 4: always true |
| `expiry.friend_invite.default_days`, `.maximum_days` | the expiry an invite gets, and the most it may ask for | rule 4: above zero, default no more than maximum |
| `audit.session_start_and_end`, `.every_command` | what the forced-command wrapper writes | always true in the data and checked by `lib/grant_compiler.py`; not one of the numbered rules. the wrapper is planned, not built |
| `audit.file_changes` | whether file changes are captured | `false`: needs kernel-level audit, designed, not built |
| `audit.agent_can_read_log`, `.agent_can_write_log` | whether the agent reaches its own log | rule 6: always false |
| `audit.retention_days` | how long entries are kept | not enforced yet; nothing rotates the log |
| `widening.*` | every way a grant could grow | rule 1: every field false |
| `owner_listed.services`, `.logs` | what operator may restart and read | not read yet |

`grant_compiler.py describe --level FILE` prints the subset `install.sh` reads, as key=value
lines: `level`, `summary`, `write_allowed`, the four friend invite values, and
`audit_retention_days`.

## rules the compiler enforces

`grant_compiler.py validate` refuses a level file that breaks any of these, and every other
subcommand validates the level first, so a broken file never reaches a plan.

1. nothing widens itself: every `widening` field is false, and `capabilities.denied` includes
   root, `sudo`, editing its own policy, editing the audit log, the kill switch, and granting
   further access.
2. observer is read only: `write_allowed` is false, and no write right appears in either the
   linux or the macos entry. this holds for any level with `write_allowed` false.
3. every path is explicit: `default_grants` is empty and `require_explicit_paths` is true.
4. friend invites always expire: `required` is true, and when invites are allowed the default
   is above zero and no more than the maximum.
5. only observer is the default level for friend invites. with several files, `validate` checks
   that exactly one, observer, is.
6. the audit log stays out of reach: `agent_can_read_log` and `agent_can_write_log` are false,
   and session and command logging is planned, not built yet.
7. passing through a parent folder grants nothing else: the linux traverse entry is exactly
   `x` and the macos one exactly `search`.
8. no capability is both allowed and denied.
9. the level name is one of the three, and `summary`, `write_allowed`, `capabilities`,
   `access_control`, `paths`, `expiry`, `audit`, and `widening` are all present.

## which paths can be granted

the compiler refuses a path, with a reason, when it

- is not absolute, or contains `.` or `..`
- is too broad: `/`, `/home`, `/Users`, `/var`, `/opt`, `/tmp`, and the like (`deny_exact`)
- sits inside a system folder: `/etc`, `/usr`, `/root`, `/System`, `/Library`, `/var/lib`,
  `/var/log`, and the like (`deny_within`)
- touches keys or credentials: any `.ssh`, `.gnupg`, `.aws`, `.kube`, `.docker`, keychains,
  and similar folders anywhere in the path (`deny_components`)
- is a whole home folder like `/home/you` or `/Users/you`; grant a project folder inside it
- belongs to the package itself: its policy, state, or audit log folders. these come from the
  package name in `project.json`, not from the level file, so no level can allow them.
- on macos, sits inside Desktop, Documents, or Downloads. macos keeps those behind privacy
  prompts that a service user cannot answer, so the alpha cut refuses them.

## what the compiler emits

output is a plan fragment: one step per line, with a title, a read-only check, and a command,
separated by tabs. paths are normalized, deduplicated, and sorted, so the same grant always
compiles to the same bytes. golden files in `tests/golden/` pin it.

for each granted path, every parent folder gets a pass-through entry so the service user can
reach the path without listing anything on the way. a parent that is itself granted is left
alone, so a pass-through entry never downgrades a grant.

on linux, for builder on `/home/you/project`, with a snapshot line before each change (see
"how a grant changes" below for what the snapshot does). the grant is done by the helper in
`lib/access_control_snapshot.py`, by file descriptor, never by path and never following a link:

```
access_control_snapshot.sh quiesce agent /var/lib/sirven/agent-quiesce.json
access_control_snapshot.sh grant-access /home yes|no agent x --snapshot ...        (no: this folder only)
access_control_snapshot.sh grant-access /home/you no agent x --snapshot ...
access_control_snapshot.sh grant-access /home/you/project yes agent rwX --snapshot ...
access_control_snapshot.sh grant-default /home/you/project agent rwX --snapshot ...
access_control_snapshot.sh release agent /var/lib/sirven/agent-quiesce.json
```

`grant-access` does what `setfacl -R -P -m u:agent:rwX` does: the agent's entry on every folder, file, pipe
and socket in the tree, links skipped, the mask recalculated, capital `X` giving execute on folders and on
files that already have an execute bit only. it opens the start folder one component at a time without
following links, checks it is the folder the snapshot recorded (same device and inode), and walks down by
descriptor, so a link the agent swaps in cannot redirect it. an earlier version ran `setfacl` by path.
`quiesce` ends every process of the agent and locks and expires its account, writing what the account was to
`agent-quiesce.json`; `release` puts it back as it was (an account that was already locked stays locked). the release step is not done while the marker is there, so a run that stopped before it is finished by the next run. `quiesce` repeats the kill until the agent has no process left (at most 20 tries). they
wrap the grant steps only when a grant step has work to do, so an install that finds everything in place
leaves a running agent alone; a rollback always runs them. whether a grant step has work to do is read from the whole tree (`verify-access`, `verify-default`), so a grant that stopped partway is finished by the next run; the mask is not compared, so an owner's chmod is not re-applied. if a step fails in between, the account stays
locked, which is the safe state, and running the same command again finishes the job.

the `-d` line makes new files inherit the grant, and it is the one that needs care. a default
list overrides the umask of whoever creates a file, and its group and other entries come from
the folder's own mode unless they are written out. so the line writes them out as `---`: a new
file gets nothing for group and other, whatever the creator's umask. the agent gets the grant
by account number, and so does the folder's owner (both looked up when the step runs, so an
owner with no account name works; root and the agent are not added as the owner), because a file the agent
creates would otherwise be unreadable to the owner. the result is never wider than a umask of
077 would give. it can be narrower: a creator whose umask is 022 gets a private file here, not
a group-readable one. `ls -l` and `stat` show the mask in the group position, because the
mask must admit the named entries. that display is not a grant to the group: `getfacl` shows
`group::---` and `other::---`, and those are what counts.

on macos, for builder on `/Users/you/code/app`:

```
/bin/chmod -h +a 'agent allow search' /Users
/bin/chmod -h +a 'agent allow search' /Users/you
/bin/chmod -h +a 'agent allow search' /Users/you/code
/usr/bin/find -P /Users/you/code/app -type f -exec /bin/chmod -h +a 'agent allow read,write,append,readattr,writeattr,readextattr,writeextattr,readsecurity' {} +
/usr/bin/find -P /Users/you/code/app -type d -exec /bin/chmod -h +a 'agent allow list,search,add_file,add_subdirectory,delete_child,readattr,writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit' {} +
```

files and folders get separate rights so plain files do not pick up folder rights. `find`
does not follow symbolic links (`-P`), and every `chmod +a` and `chmod -a` has `-h`, so a file swapped for a link
between `find` and `chmod` never gets an entry on whatever the link points at. `-h` protects the last path
component only; a swapped intermediate folder is a remaining risk, not run on a Mac.

`revoke` emits the matching removals, the grant first and the pass-through entries last.

`compile --with-undo` adds three more fields to the snapshot line of each folder, the title, check,
and command that put its access control lists back. `install.sh` compiles this way, so each
snapshot it really applies goes into the install record with its undo. every snapshot comes
before the first change, so a path nested inside another granted path is recorded before the
outer grant reaches it.

## grant record

the installer writes the grant it applied to `/etc/<package>/grants/<user>.json`, owned by root.
the kill switch reads it to know what to remove.

```json
{
  "can_grant": false,
  "expires": null,
  "level": "builder",
  "paths": ["/home/you/project"],
  "principal": "owner-agent",
  "schema_version": 1,
  "user": "agent",
  "write_allowed": true
}
```

## how a grant changes, and how it is reversed

- **setup.** before the plan is built, `install.sh` asks at most two questions, each with its
  default in brackets: the access level (`observer`) and the one path to grant (the current
  folder when the level's policy accepts it, otherwise `none`). the plan header then shows the
  level and paths chosen, and nothing applies without that plan being printed. a flag
  (`--level`, `--path`) or an environment variable (`SIRVEN_LEVEL`, `SIRVEN_PATH` with paths
  separated by colons, or `none`) answers a question ahead of time, and flags win. with `--yes`
  (`--defaults`, `SIRVEN_YES=1`), or with no terminal to ask on, nothing is asked: the level is
  `observer` and no path is granted, because a grant needs a person to name the path.
  `curl ... | bash` with a person at the terminal still asks, on the terminal.

  ```
  sirven setup: press enter to accept the default in brackets.
  1/2 access level [observer]: builder
  2/2 path to grant [/home/you/code/app]:
  ```
- **re-run.** with a grant in force, `install.sh` adopts it: a level or path not given by a flag
  or the environment comes from the grant record, nothing is asked for it, and the plan shows it
  as `adopted:`. giving a different level or path is a grant change, shown as one. granting no
  path over a grant in force, or reinstalling a level whose policy copy was edited, is refused
  before any change (exit 2, no plan). a dry run prints the whole plan with each such conflict as
  a step blocked by the conflict, ends with a line saying a real run would refuse, and also exits
  2. see `lib/adopt.sh`.
- **install.** `install.sh` writes the grant record and the entries. when it applies for real,
  each step it actually runs appends its undo to the install record,
  `/var/lib/<package>/install-record.tsv`, and a changed grant record writes a `grant` entry to
  the audit log with the level and paths before and after. steps found already done are not
  recorded: the package did not create them.
- **inspect.** `bin/sirven grant inspect` reads the grant records, says whether the installed
  policy copy still matches `levels/`, and shows the last grant entry from the audit log.
- **refusal (linux).** before anything changes, the plan reads the granted folders and the parents the
  agent passes through (`lib/access_control_snapshot.sh check`). a grant recalculates the mask. that
  widens another account only where the account has an entry with bits the mask now switches off (a file
  with `user:bob:rw-` and `mask::r--` lets bob only read; after the grant he could write). so the check
  refuses exactly that: an entry for another account or a named group with bits outside the current mask.
  an entry that fits inside the mask is fine, however many there are. it never counts the agent's own and
  the folder owner's entries (an earlier grant), and it skips every path the agent owns, because the agent
  can put any entry on its own files itself: so the agent can never block a step down to a lower level or
  a rollback. the group entry is not refused either: the grant narrows the group entry and the other named
  entries to the old mask before it raises the mask, so an owner's `chmod 600` is not undone by a re-grant
  and the group stays shut out. up to ten paths are listed, with `setfacl -x u:NAME PATH` as the way on. the
  check is read only, and under `--dry-run` as an ordinary user it says it could not read every path instead
  of refusing. the one case still refused after an owner narrowed a mask: another account's own entry would be
  switched back on by the re-grant.
- **snapshot and restore (linux).** before a grant changes a folder, install records it:
  for a granted folder, every folder in it (path, device, inode), the default list of each, and any
  entries of the agent or the folder owner from an earlier grant; for a parent the agent only passes
  through, the folder alone. the record is a root-only file in `/var/lib/<package>/access-lists/`,
  named after a hash of the path. names are recorded as bytes, so a newline or a backslash in a name
  is safe.

  **exactly what undo changes**, and nothing else: on every path in the tree, the named entries for the
  agent (and for the folder owner, where the agent's entry is also there); on folders, the default list
  when it carries the agent's entry, replaced by the one recorded before the grant (if there was one).
  when a path had named entries before the grant, its recorded mask comes back (not the wider one the grant raised it to). when no named entry is left on a path, its list collapses to a plain mode: the group bits become the
  group entry AND the mask, which is what the group could really do. it **never changes an owner or a
  group, and never touches the owner bits, the other bits or the special bits** (setuid, setgid, sticky).
  so a `chmod 600` the owner made during the grant, a `chown` or `chmod` by root, a setuid bit, and a
  `chmod 700` on a pass-through parent all stay. one deliberate exception: while a list has a mask,
  `chmod` changes the mask, not the group entry, so a chmod that **widens** the group bits during the grant
  (644 to 664) does not survive undo (the file ends 644, which is what the group could do all along).
  using the mask as the group bits would have widened access nobody granted.
  this holds for uninstall, rollback and the kill switch alike.

  **the snapshot is as large as the lists the tree already had, not as large as the tree.** it records only paths
  that held a list before the grant (a default list, a mask, a named entry: earlier default lists, earlier entries of
  the agent or the folder owner), written into a sqlite file as the walk goes and looked up by device and inode
  when undo meets each path, so nothing is loaded whole. an agent that makes 300,000 empty folders adds nothing to
  it and costs 15 MB to record and 15 MB to restore (it was 239 MB and 335 MB). the cost is that the warning for a
  folder the agent replaced with a link now names only folders that held a list; a swapped folder with no list
  of its own is not followed either, but is not named in the audit log. snapshots written by earlier versions of this
  package (a text format) are not read: undo treats them as missing, removes the grant's entries and warns.

  **a snapshot that cannot be used.** the Linux preflight refuses a python3 without the sqlite3 module before any
  change (install the python3 standard library package; `python3-minimal` without the recommended packages leaves it
  out). when a snapshot is checked as it is opened (a quick integrity check of the whole file) and found damaged, in
  its header or in its middle pages, or goes bad during the walk, undo removes the grant's entries anyway, warns
  loudly (also as an audit `warning` event), and renames the file aside as `NAME.unusable-TIMESTAMP`, printing the new
  name; it is never deleted, and it is a sqlite file whose `entries` table holds the lists. what is lost is only the
  lists the folder had before the grant (an owner's own default list, a mask): they are not put back, and the warning
  says so. a snapshot that python3 cannot read for lack of the module is left where it is, and the same command works
  once the module is installed. a snapshot locked by another process is not unusable: undo waits
  (`SIRVEN_SNAPSHOT_WAIT` seconds, default 30), then fails with the file untouched and says to end that process and
  run the same command again; nothing is removed, the account stays locked until it does.

  **memory.** the walk keeps no path per open folder and no listing for a folder it let go of: a folder is a
  few small values and its own name, the path is built only when something is printed, and a let-go folder is
  listed again (sorted, resuming after the last name read) when it is reopened. problems are counted and only
  the first ten are kept. so 3,000 levels of 255-character names, or 240,000 long-named files, stay under about
  25 MB in the install-time check and in uninstall, and a tree of 301,001 entries takes about 10.5 s to
  install and 4.0 s to uninstall, each with about 15 MB in the helper. a folder lost from under the walk (moved, replaced or removed after it
  was let go) is an error with a recovery hint, never a silent skip.

  **depth and descriptors.** the walk is iterative and keeps the deepest 48 folders open, whatever the depth,
  so a chain of 12,000 folders made by the agent undoes under an open-file limit of 1,024. a folder let
  go is opened again through `..` and checked against the device and inode recorded when it was first
  opened (a slow reopen by name if the tree was moved). a path deeper than 30,000 levels is reported by
  name and skipped, with a hint to remove it (`rm -r`) and run again. no exception leaves as a traceback; a
  failure prints `error:` lines and a `recovery:` line, and the account stays locked and expired until a run
  finishes, which the install, rollback and uninstall messages say, with how to give it back now
  (`access_control_snapshot.sh release AGENT MARKER`).

  **AppArmor (SIR-83, measured on the server ba-sing-se).** with AppArmor enforcing under its docker-default
  profile, the agent cannot build a deep chain at all: its folder creation stops at depth 4,090 with Errno 36
  (ENAMETOOLONG), at about 8,189 bytes of absolute path. unconfined, the same chain reaches 12,000 levels. the
  harness scenarios 67 (revoke) and 68 (uninstall) keep the default profile and check that, on the deepest chain
  the confined agent can build, every access list entry is removed and no process is left. revoke (scenario 67) also locks the account;
  uninstall (scenario 68) removes the service user. the SIR-83 commit message records both passing on the server
  ba-sing-se (zero access list entries left); not re-run from this Mac. not yet verified: a tree
  built with AppArmor lifted, then revoked under the default profile. the attempt to carry such a tree between two
  containers failed (a committed image kept only about 1,996 levels and lost the grant), so that case is open.

  **links.** undo never follows a link. it opens the granted folder one component at a time without
  following links and checks it is still the folder that was recorded (same device and inode),
  then walks down by file descriptor and reads and writes the list on the open descriptor, so there is
  no path to swap under it. a folder the agent replaced with a link is skipped, and a warning
  event goes to the audit log. before the first list is put back, undo expires the agent's account and
  ends its processes, so nothing the agent runs can change the folders meanwhile (a rollback ends the agent first too, at the start of its removal, and gives the account back at the end,
  also when it goes back to no grant).

  **a missing or unusable snapshot.** undo does not treat that as done. the step's check is the state
  of the folder (an entry of the agent left, or the snapshot still there), not whether the snapshot
  file exists. with no snapshot it still removes everything the grant added, prints `warning: could
  not restore the earlier access control lists ...`, and writes a `warning` event to the audit log. it
  exits 0, because a non-zero exit would stop uninstall before the account is removed. what it cannot
  put back is a default list the folder had before the grant. look with `getfacl -R -p FOLDER`.
  a pipe, socket or device in the tree is reached through an `O_PATH` descriptor, never opened.

  **installs made before this change.** the install record stores the undo command text, so an install
  made by an earlier version keeps its old undo (`setfacl -R -P -x u:agent` and `-d -x`, or the
  first version of the snapshot helper), which leaves the default list, the mask and the folder
  owner's entry behind. an install of that kind exists only if an earlier version was applied to a real machine: before real apply on Linux the alpha cut applied only in throwaway containers, and macOS apply is off by default. to repair one, from a checkout of this package, as root:
  `bash lib/access_control_snapshot.sh repair FOLDER yes AGENT` for each granted folder, and
  `... repair PARENT no AGENT` for each pass-through parent, before running uninstall. repair is
  the no-snapshot removal above and changes no mode.
- **rollback.** `bin/sirven grant rollback` takes the newest `grant` entry, refuses if the grant
  record no longer matches it, removes every current entry, and grants the earlier level and
  paths again. it writes its own `grant` entry with the reason `rollback`, so a second rollback
  undoes the first. the removal undoes the grant the same way uninstall does (see exactly what undo changes), so an
  owner's chmod made since the install survives it, and the earlier grant takes a new snapshot. what it grants goes into the install record too.
- **kill switch.** `sudo /usr/local/sbin/sirven revoke --all` cuts the agent off now and keeps every
  record. it applies on Linux, in a container and on a real machine (a real Linux apply needs root), and asks you to type `revoke` first unless `--yes` is given. on macOS it is still
  plan output. in order, each step attempted even when an earlier one failed:
  (0) the kill switch's own marker `agent-revoked-USER.json` (one per account) is written in the state directory, before anything else changes;
  (1) in one `usermod` call the account is locked, expired and given the `nologin` shell, and every process of the agent,
  by effective and by real user, is ended, repeatedly until none is left; (2) every service, timer, socket and path unit
  that runs as the agent or starts its work (template instances included) is stopped (triggers first) and disabled, its
  lingering turned off and its systemd session ended; (3) its cron and at jobs are removed; (4) `authorized_keys` and
  `authorized_keys2` are removed by `lib/kill_switch.py`; (5) every granted folder is put back from its snapshot with the
  same `restore` uninstall uses, for the paths in the grant record plus any `--path`; (6) the grant record is renamed
  `<user>.json.revoked` (an earlier revoked record is kept beside it under a time stamp; the rename is recorded in the
  install record so uninstall removes it; left in place if any restore failed, so the next run still knows what to take back);
  (7) the install's own marker `agent-quiesce.json` is deleted; (8) the transport is closed (the tunnel this installer made is taken away: its service is stopped and removed, its credentials and config deleted, and in the Cloudflare account the tunnel and the alias record it made are deleted, each only while it is still the one recorded, which needs the API token again and otherwise fails loudly and can be run again;
  a node this installer joined to the tailnet is logged out, and only that node; an unused Tailscale auth key is removed; the tailnet policy and the Cloudflare Access application and service token are the owner's, by hand);
  (9) last, the machine is looked at, not the exit statuses: no process of the agent (one that comes back, because
  something of the owner's starts it, is ended again up to six times, then the run fails loudly and says how to find what starts it),
  the account locked and expired, no service, no keys, every folder put back. the install record, the audit log, the revoke
  marker and the agent's home folder are kept.

  the account is cut off in layers, each enough alone: the keys are gone, the account is expired (sshd refuses it even with
  a key put back, which the harness tests), the password is locked and the shell is `nologin`. the lock comes first and does
  not depend on anything after it: a grant record that cannot be read, or a path the grant compiler refuses, becomes a step
  after the keys, so the run fails but the agent is already out.

  **it refuses the wrong account.** `--user` may not name root, the owner, the user who ran `sudo`, `nobody`, or any account below
  `UID_MIN` (read from `/etc/login.defs`, 1000 when it says nothing): exit 2, nothing changed.

  **no link is followed.** the agent owns its home folder and its `.ssh` folder, so any name in them can be a link it planted
  to a file that matters. the keys are not emptied by path (that writes through a link): the home folder and `.ssh` are opened
  without following a link and the names are removed with `unlinkat`. a `.ssh` that is itself a link, a regular file, a pipe or
  a socket is removed as a name, so one planted name never stops the other steps. the folders are put back by the descriptor
  walk described above, which skips links. the harness plants links to root's own `authorized_keys`, to a root-only file and
  folder, and over `.ssh`, and checks each target keeps its content, owner, mode and lists.

  **every step is attempted, and the run is loud.** a step that fails is recorded and the others still run; the run ends
  with exit 4, lists every failed step, writes `revoke_finished` with `outcome: failed`, and says what to do: fix the cause and run
  `revoke --all` again. each step's check is read again just before the step runs, and every finished step is skipped on
  the next run. the account is not given back (an install or a rollback gives it back; the kill switch never does).
  `revoke_started` is the first audit entry of a run and `revoke_finished` the last; every step also writes its own entry.
  one run at a time: install, uninstall, rollback and repair hold a lock on the state directory (they refuse if another run
  keeps it for a minute); the kill switch waits ten seconds and goes on, because it must not be blocked.

  **a stopped revoke is never undone by an install.** the marker `agent-revoked-USER.json` (one per account) is separate from the install's
  `agent-quiesce.json` (which remembers the account's earlier state so a finished install can give it back). while the marker is
  there, install refuses (exit 2, in a dry run too where the plan is printed with the refusal as a blocked step, and also when the kill switch stopped halfway), and the step that gives an
  account back (`release`) refuses too. install also refuses an account that is left expired when no install was in the middle of
  changing it. `sirven grant rollback` is refused (the grant record no longer matches the audit log). the owner brings the
  account back on purpose with `install.sh --reinstate`: it unlocks the account, removes the expiry, gives back the `/bin/bash`
  shell, removes the marker, writes a `reinstate` audit entry, and goes on with the install. the removed keys, services, jobs
  and grant do not come back. the kill switch itself never takes `--reinstate`.

  **root runs only code that root controls, and the path to it is built in, not looked up.** an agent that edited a copy of this
  package, for example one inside the folder it was granted, must never have its edits run as root. so, as root, on every
  command and every flag (`--dry-run`, `--help` and `--prefix` included, because a dry run reads the same code):
  the same block of text sits at the top of `install.sh`, `uninstall.sh` and `bin/sirven` (a test keeps the three equal) and runs
  before any library is read. it resets the search path to `/usr/sbin:/usr/bin:/sbin:/bin` and names the tools it uses by absolute
  path (`/usr/local/sbin` and `/usr/local/bin` are added after those only when root alone controls each one, the folders above it
  and what is in it, checked at that moment; a folder that fails is left out and the run says so, so tailscale or cloudflared installed
  there are found, and a folder the agent can write never is; each is resolved to its physical path first and that path is the one checked and
  used, so a link that can be swapped after the check changes nothing); it takes the kept copy from the constant `/var/lib/sirven/package`, never from `project.json` or any file of the folder
  under test (the package name must also be a plain lowercase name, and a `--prefix` that is or resolves to `/` is refused,
  because it used to turn into a real run); the checker is the text of the block, not a file of the folder it judges; the
  folder is resolved to its physical path once and every library is read through that path, so a link swapped in later changes
  nothing. then: when a kept copy exists and this is not it, the kept copy runs instead, after the kept copy is checked too
  (install is the exception, because it is how a newer release replaces the kept copy; it runs from where it was started only
  if nobody but root and the owner who ran `sudo` can write that folder, and runs the kept copy otherwise). with no kept
  copy (the first install), the folder must be one nobody but root and the owner can write. "can write" is judged on every
  file and folder of the package tree and every folder on the way to it: owner, mode, group members, and access list entries; a
  link that leaves the package is refused; a read-only mount is **not** taken as safe, because the same files can be writable
  through another mount. the state directory is forced to mode 0700 and root as owner whether or not this run made it.
  a `--prefix` with a `.` or `..` component is refused whether or not the folders exist, and a started-from-standard-input script is refused.
  the safe way to run any root command is the launcher `/usr/local/sbin/sirven`, written by install, root-owned, mode 755: it
  sets its own search path and runs the kept copy. install writes it only if `/usr/local/sbin` and every folder above it can be written by
  root alone (the same checker); otherwise it writes nothing, says so, and every message gives the kept-copy command instead
  (`sudo bash /var/lib/sirven/package/install.sh revoke --all`). with the launcher (`sudo /usr/local/sbin/sirven revoke --all`, `... uninstall`, `... grant rollback`,
  `... install --reinstate`). the one limit left is the first install: it runs from the folder it was unpacked in, so unpack it where
  only you can write, and delete it afterwards, or grant a path that does not hold it. the harness covers each route the reviews
  found (scenarios 40 and 46 to 53, and `tests/harness/run-ro-bind.sh`).

  **uninstall is link-safe too.** the undo of the key files and of the `.ssh` folder calls the same helper instead of `rm`
  and `rmdir` by path, so a plain uninstall (no revoke first) cannot be steered through a link the agent planted: a `.ssh`
  that is a link is removed as a name and the folder it pointed at is left alone. installs made by an earlier version keep
  their old recorded undo (`rm -f` by path); run this version's kill switch before uninstalling such an install.
- **uninstall.** `uninstall.sh` reverses the install record in reverse order: the snapshots restore
  each folder first, then the service user, then files and folders, which are removed only when
  empty. the audit log stays unless `--remove-audit-log` is given.

no step in any of these widens a grant beyond what a level file allows: rollback and uninstall
only ever apply grants the compiler produced from a level, or remove entries.

## friend invites (designed, not built)

```
invite --level observer --path ~/code/app --key <their public key> --expires 7d
revoke <invite>
```

- an invite is a grant bound to one public key, added to the service user's authorized keys
  with a forced command that writes every command to the audit log.
- the level defaults to observer. builder needs the owner to ask for it by name, and its expiry
  is shorter. operator is never available to a friend.
- `--expires` is mandatory and capped by the level's `maximum_days`. an expired invite is
  removed the same way `revoke <invite>` removes it.
- the principal in the grant record and the audit log is `invite:<name>`, never `owner-agent`.

## known limits in the alpha cut

- macos: the steps run on a fake root and are tested, but a real apply is switched off until
  tests/macos/real-install-check.sh has passed on a real Mac, with the owner's approval (see
  docs/research/qa/macos-real-apply-prep.md). the macos entries name the agent only, so no group
  or other entry is copied and the linux default-list problem has no macos form.
  macos undo is not a subtraction. `chmod +a` merges rights into an entry that is already there, a
  file created in a granted folder inherits an entry built from the folder rights, and `chmod -a` of
  a different right set leaves a remainder and fails on an item with no list. so the undo is
  `lib/access_control_macos.sh sweep`: it removes every entry that names the service user from the
  granted folder and everything inside it, never following a link, and the install first refuses a
  tree where that account already has an entry, and a granted path that is a link. the service user
  is made by the install, so it holds no entry anywhere before the grant, and the sweep restores
  every list exactly. `revoke` (the kill switch) builds its access control step from the same sweep, so
  revoke and uninstall agree and both leave no entry that names the service user. macos revoke is still plan
  output until a run on a real Mac verifies it; the sweep commands themselves are tested on a real Mac inside
  a scratch folder.
- the grant, the check and the undo are all descriptor based, so no path is followed after the start
  folder is opened. who could race a first install: no agent process exists yet, and the folder owner or a
  collaborator who can write in the tree could plant a link, but the grant does not follow it, so they gain
  nothing from root's grant. what is still by path is read only: the plan's `getfacl` and `stat` probes (which
  decide a step is already done), and the first `realpath` of the granted folder, which is checked against the
  snapshot's device and inode before anything is changed.
- a grant over a tree that already has named entries for other accounts, or a mask, is refused, not
  merged. nested grants by two different folder owners are refused for the same reason (the second
  owner's entries look like foreign lists).
- files and folders the owner creates during a grant stay private after undo: a new file gets nothing
  for group and other, and undo leaves the mode as it is. with umask 022, folders end as 755 with files
  inside at 600, and copies are 660 during the grant. a web server or teammate who read by group or
  other cannot read files made during the grant, and a shared setgid folder loses group sharing for new
  files while the grant is in force. this is the safe direction.
- the default list makes group and other bits show the mask. no grant with a named entry can show
  `600` for a new file; the effective access is what to check.
- on macos, `file_inherit` copies the folder entry onto new files, and folder `list` and
  `search` are the same bits as file `read` and `execute`. new files in an observer grant can
  therefore pick up execute for the agent. it cannot write them.
- the agent owns its home, so it can add a key to its own authorized keys. that key logs in as
  the same service user with the same rights, so it widens nothing, and the kill switch locks
  and expires the account, which stops every key at once.
- operator's extra capabilities are designed, not built. today operator compiles to the same
  entries as builder, and `owner_listed` is read by nothing.
- `audit.retention_days` is not enforced: nothing rotates or trims the log yet.
- reinstalling with different paths adds the new entries but does not remove the old ones.
  use `bin/sirven grant rollback`, or the kill switch, to remove access.
- audit capture per session and per command is designed, not built: it is meant to come through
  the forced-command wrapper. a process the agent starts can do things that wrapper would never
  see.
