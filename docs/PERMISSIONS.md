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
- `audit`: sessions and commands are always logged; the agent can never read or write the log
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
| `audit.session_start_and_end`, `.every_command` | what the forced-command wrapper writes | rule 6: always true. the wrapper is built after alpha |
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
   and sessions and commands are always logged.
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
  before any change. see `lib/adopt.sh`.
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

  **memory.** the walk keeps no path per open folder and no listing for a folder it let go of: a folder is a
  few small values and its own name, the path is built only when something is printed, and a let-go folder is
  listed again (sorted, resuming after the last name read) when it is reopened. problems are counted and only
  the first ten are kept. so 3,000 levels of 255-character names, or 240,000 long-named files, stay under about
  25 MB in the install-time check and in uninstall, and a tree of 301,001 entries takes about 11.5 s and 61 MB to
  install and 4.4 s and 88 MB to uninstall. a folder lost from under the walk (moved, replaced or removed after it
  was let go) is an error with a recovery hint, never a silent skip.

  **depth and descriptors.** the walk is iterative and keeps the deepest 48 folders open, whatever the depth,
  so a chain of 12,000 folders made by the agent undoes under an open-file limit of 1,024. a folder let
  go is opened again through `..` and checked against the device and inode recorded when it was first
  opened (a slow reopen by name if the tree was moved). a path deeper than 30,000 levels is reported by
  name and skipped, with a hint to remove it (`rm -r`) and run again. no exception leaves as a traceback; a
  failure prints `error:` lines and a `recovery:` line, and the account stays locked and expired until a run
  finishes, which the install, rollback and uninstall messages say, with how to give it back now
  (`access_control_snapshot.sh release AGENT MARKER`).

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
  owner's entry behind. the alpha cut applies only inside throwaway containers, so none exist outside
  them. to repair one, from a checkout of this package, as root:
  `bash lib/access_control_snapshot.sh repair FOLDER yes AGENT` for each granted folder, and
  `... repair PARENT no AGENT` for each pass-through parent, before running uninstall. repair is
  the no-snapshot removal above and changes no mode.
- **rollback.** `bin/sirven grant rollback` takes the newest `grant` entry, refuses if the grant
  record no longer matches it, removes every current entry, and grants the earlier level and
  paths again. it writes its own `grant` entry with the reason `rollback`, so a second rollback
  undoes the first. the removal undoes the grant the same way uninstall does (see exactly what undo changes), so an
  owner's chmod made since the install survives it, and the earlier grant takes a new snapshot. what it grants goes into the install record too.
- **kill switch.** `install.sh revoke --all` runs the same undo for each folder, with or without a snapshot, and renames the grant record to `<user>.json.revoked`. plan output
  in the alpha cut.
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

- macos entries are plan output only. they need a run in a macos virtual machine before apply
  is turned on. the macos entries name the agent only, so no group or other entry is copied and
  the linux default-list problem has no macos form, as far as the entries show. macos undo is
  unchanged in kind: it removes the entries it added by their exact text, now with `-h`. not run on a Mac.
  the manual check, on a test Mac: (1) `ls -lde` the granted folder, a file in it, and every parent up to
  `/Users/you` (the parents show the pass-through entry), before apply. (2) apply, then `ls -le` the
  same paths and confirm the agent's entries are the only new ones. (3) `umask 077`, create a file in the
  folder, `ls -le` it, and confirm the agent's inherited entry is the only one for it. (4) as the owner,
  `chmod 600` a pre-existing file in the folder, then revoke or uninstall, and confirm that file is
  still 600 and `ls -le` of every path matches the listing from step 1. (5) make a link inside the
  granted folder that points at a folder outside it (`ln -s ~/.ssh /granted/link`) before apply, and
  confirm `ls -le ~/.ssh` is the same after apply and after revoke.
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
- audit capture is per session and per command through the forced-command wrapper. a process
  the agent starts can do things the wrapper never sees.
