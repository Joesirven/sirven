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
6. the audit log stays out of reach: `agent_can_read_log` and `agent_can_write_log` are false.

## which paths can be granted

the compiler refuses a path, with a reason, when it

- is not absolute, or contains `.` or `..`
- is too broad: `/`, `/home`, `/Users`, `/var`, `/opt`, `/tmp`, and the like (`deny_exact`)
- sits inside a system folder: `/etc`, `/usr`, `/root`, `/System`, `/Library`, `/var/lib`,
  `/var/log`, and the like (`deny_within`)
- touches keys or credentials: any `.ssh`, `.gnupg`, `.aws`, `.kube`, `.docker`, keychains,
  and similar folders anywhere in the path (`deny_components`)
- is a whole home folder like `/home/you` or `/Users/you`; grant a project folder inside it
- belongs to the package itself: its policy, state, or audit log folders
- on macos, sits inside Desktop, Documents, or Downloads. macos keeps those behind privacy
  prompts that a service user cannot answer, so the alpha cut refuses them.

## what the compiler emits

output is a plan fragment: one step per line, with a title, a read-only check, and a command,
separated by tabs. paths are normalized, deduplicated, and sorted, so the same grant always
compiles to the same bytes. golden files in `tests/golden/` pin it.

for each granted path, every parent folder gets a pass-through entry so the service user can
reach the path without listing anything on the way. a parent that is itself granted is left
alone, so a pass-through entry never downgrades a grant.

on linux, for builder on `/home/you/project`:

```
setfacl -m u:agent:x /home
setfacl -m u:agent:x /home/you
setfacl -R -P -m u:agent:rwX /home/you/project
setfacl -R -P -d -m u:agent:rwX /home/you/project
```

`-P` keeps the walk from following symbolic links out of the granted folder. the `-d` line makes
new files inherit the grant. capital `X` gives execute on folders only, not on every file.

on macos, for builder on `/Users/you/code/app`:

```
/bin/chmod +a 'agent allow search' /Users
/bin/chmod +a 'agent allow search' /Users/you
/bin/chmod +a 'agent allow search' /Users/you/code
/usr/bin/find /Users/you/code/app -type f -exec /bin/chmod +a 'agent allow read,write,append,readattr,writeattr,readextattr,writeextattr,readsecurity' {} +
/usr/bin/find /Users/you/code/app -type d -exec /bin/chmod +a 'agent allow list,search,add_file,add_subdirectory,delete_child,readattr,writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit' {} +
```

files and folders get separate rights so plain files do not pick up folder rights. `find`
does not follow symbolic links.

`revoke` emits the matching removals, the grant first and the pass-through entries last.

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
  is turned on.
- on macos, `file_inherit` copies the folder entry onto new files, and folder `list` and
  `search` are the same bits as file `read` and `execute`. new files in an observer grant can
  therefore pick up execute for the agent. it cannot write them.
- the agent owns its home, so it can add a key to its own authorized keys. that key logs in as
  the same service user with the same rights, so it widens nothing, and the kill switch locks
  and expires the account, which stops every key at once.
- operator's extra capabilities are designed, not built. today operator compiles to the same
  entries as builder.
- audit capture is per session and per command through the forced-command wrapper. a process
  the agent starts can do things the wrapper never sees.
