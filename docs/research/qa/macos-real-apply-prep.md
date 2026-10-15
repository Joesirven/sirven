# macos real apply: what is ready, what the check proves, what is still unverified

Branch `v0.2-macos-real-apply-prep`, from `origin/main` at 713659b. Written on Omashu (Jose's MacBook
Pro). Nothing was changed on this Mac outside temporary folders: no sudo, no account, group, or access
control list outside a folder the tests made, no `install.sh` or `bin/sirven` run without `--dry-run`
or `--prefix`, no system setting. `tests/macos/real-install-check.sh` was **not** run with approval
(only its refusal and its `--rehearse` mode, on a fake root).

On this Mac `make test` at origin/main already fails three tests that have nothing to do with this change
(`test_install_started_by_sh_says_to_use_bash`: `/bin/sh` is bash here; `test_enter_twice_accepts_the_shown_defaults`
and `test_input_that_ends_takes_the_defaults`: they compare a temporary path that macos spells `/private/var`).
The same three fail with this branch.

## What is ready

Every macos install step and every uninstall step is now a real, runnable step. On a fake root
(`--prefix`) they are recorded and the record is reversed by `uninstall.sh`; on a real Mac they stay
switched off (below).

| Area | Before | Now |
| --- | --- | --- |
| Service user | plan only | `service_user_macos_create` (`lib/service_user.sh`): `dscl` records, a generated identifier, a private home folder, hidden, no password, primary group staff. One command in one step, chained, so a failed attribute fails the step. A half-made account is finished on re-run (it keeps its number); an account this call started and could not finish is deleted again. The done check reads the end state (number, identifier, hidden, home path, no password, home folder on disk), not just that a record exists. |
| Not an administrator | `dseditgroup` comment | a real step, `service_user_refuse_admin`, which reads `id -nG`; it runs every time, as on linux. |
| Folder and key file | plan only | two real steps, `install -d` and `install -m 0600`, each with its undo. |
| Folder access | plan only | `chmod -h +a` through `find -P`, as compiled by `lib/grant_compiler.py` (unchanged output). |
| Undo of folder access | subtraction of the rights added | a sweep (`lib/access_control_macos.sh sweep`, run from the pinned copy): removes every entry that names the service user from the granted folder and everything inside it, highest index first, never following a link. |
| Sweep and account undo guards | none | file names are listed with `ls -b`, so a newline in a name cannot forge a list entry or heading; a granted path that became a link is refused by sweep and status; the account undo (`lib/service_user_macos.sh remove`) deletes only while the real name is still `sirven agent`; existence is judged by `RecordName`, so a record with no number is never deleted by cleanup and counts as a foreign account. |
| Refusals before any change | none on macos | a granted path or pass-through parent that is a link (find -P on a link grants nothing); an existing entry for the account in the tree; an account of that name this package did not make (its real name is not `sirven agent`). Read only; real root only. |
| Real apply | refused always | refused unless `SIRVEN_MACOS_REAL_APPLY=1` is set **and** the user is root. Off by default. |

### Run the opt-in only from a folder only the owner can write

On macOS the root-trust check at the top of `install.sh`, `uninstall.sh` and `bin/sirven` returns at once, so with
`SIRVEN_MACOS_REAL_APPLY=1` as root it does not vet the folder the code runs from, and code in a folder the agent can
write would run as root unchecked. Run the macOS opt-in only from a folder only the owner can write, such as the
bootstrap's temporary folder, never from a folder the agent has been granted.

### Why the undo is a sweep (found by running `chmod` in a temporary folder)

The old macos undo subtracted the exact rights the grant added. On this Mac that fails in four ways:

1. `chmod +a` of the same principal merges rights into the entry already there (the comment in
   `bin/sirven` saying it adds a second entry is wrong). Subtracting then strips rights the account held before.
2. A file created in a granted folder inherits an entry built from the folder rights (`list` becomes
   `read`, `search` becomes `execute`). Subtracting the file rights left `inherited allow execute` behind.
3. `chmod -a` on an item with no list exits 1 (its error says no list is present), and on a list with no matching entry
   exits 1 (its error says the entry is not found). Inside `find -exec ... {} +` one such item fails the whole undo step. A
   file moved in with `mv` is enough.
4. The check looked at the top folder only.

The service user is made by the install, so it holds no entry anywhere before the grant (the refusals
above enforce it). Every entry that names it was added by the grant, so removing all of them puts every
list back exactly. Mode bits are never touched: a macos list lives beside them.

**Revoke now agrees:** `revoke_macos` in `lib/grant_compiler.py` builds its lines with `macos_sweep_removal`, the same
function the undo of a grant and uninstall use, so revoke has neither problem 2 nor problem 3. The golden files
`revoke-fragment-macos-builder.txt` and `revoke-macos-cloudflare.txt` changed with it. The kill switch on macos is
still plan output; a real revoke run on a Mac (root, the service user, the lock and the keys) is not verified.

### Switching real apply on

```
sudo env SIRVEN_MACOS_REAL_APPLY=1 bash install.sh --level observer --path /some/folder ...
```

`sudo` drops the variable without `env`, so `SIRVEN_MACOS_REAL_APPLY=1 sudo ...` would leave it off and be
refused. Only the exact value `1` counts. The refusal text says all this. `uninstall.sh` and
`sirven grant rollback` call the same function. Rollback on macos stays refused (its removal steps are
plan only): its removal lines are the revoke lines, which are now the sweep. It is still not verified on a real Mac, and a
sweep of a path nested inside another granted path would also take the entries the outer grant put there, so rollback
needs that looked at before it is switched on. It is not part of install or uninstall.

Merge note: this branch changes only the macos arm of `plan_real_apply_refusal` (`lib/plan.sh`): that
arm now calls `plan_macos_real_apply_refusal`, defined just above it. A sibling branch editing the linux
arm of the same function will touch neighbouring lines.

## What the check script proves (when run with approval)

`sudo bash tests/macos/real-install-check.sh --i-have-approval`. It refuses without the flag, off macos,
without root, without `SUDO_USER`, and if either throwaway account already exists. It uses two
throwaway accounts (`checkobserver`, `checkbuilder`) and a throwaway folder `/Users/Shared/sirven-check.XXXXXX`
(not `/tmp`, which is a link; not a privacy folder) holding a granted folder, an outside folder, and two
links that point outside. Every folder is mode 0700, so the only way in is the access control list.

For the observer level, then the builder level (an uninstall between them, so nothing stacks):

1. Writes the before state: accounts with numbers, groups with numbers, the admin and staff members,
   remote login members and setting, the lists on `/Users`, `/Users/Shared`, the throwaway folder and the
   granted folder, every item in and outside the grant (mode, owner, group, entries, no times), every
   file under `/etc/sirven`, `/var/lib/sirven`, `/var/log/sirven`, and the check home folders.
2. Prints the real dry run and checks it changed nothing (state diff empty).
3. Runs the real install, then checks: install record root-only; pinned copy; policy copy equals the
   shipped file; grant record; audit log with a finished entry; the account has a number and an identifier,
   is hidden, has `*` as password, the planned home path; an empty and a wrong password both fail
   `dscl -authonly`; not in the admin group by two tests; home, `.ssh` and key file private and empty.
4. Access as the account (`sudo -u`): reads granted files and subfolders and lists the folder; observer
   cannot write or create; builder can write, create a file and a folder, and the new file carries an
   inherited entry; it cannot read or list outside the grant, cannot read or list through either link, no
   entry landed on what the links point at, no `sudo`, cannot change its policy, the audit log, the grant
   record, or read the install record. Whether it can list the owner's home is printed as a note (that
   is the Mac's own setting).
5. Runs the install again: exit 0, at most one step applied (the not-an-administrator confirmation has
   no read-only probe of its end state, so it runs every time, as on linux), and the finished steps skipped.
   In a rehearsal even that step counts as done, so the rehearsal cannot see the difference.
6. Runs the uninstall **from the pinned copy** (`/var/lib/sirven/package/uninstall.sh`), the path a user
   has when the download is gone.
7. Writes the after state and diffs it against the before state. The only differences allowed are the
   account's kept home folder and the audit log (both checked on their own), and the file and folder the
   builder account made in the granted folder, which stay through the uninstall on purpose: they carry
   inherited entries, so "no entry of the account is left" on them is the real test of the sweep. It also checks that no
   entry of the account remains in the granted folder, and that the account is gone.

It keeps going after a failed check so the uninstall still runs and puts the machine back. It prints
what it left behind (home folders, audit log, throwaway folder) with the commands to remove them; it
removes none of it. `--rehearse EMPTY_FOLDER` runs the same sequence on a fake root with no root and no
approval: it proves the order of steps, the record, and the files the package writes (36 checks pass, 4
real-account checks skipped). `tests/unit/test_macos_apply.sh` runs the refusal and the rehearsal.

## What was proven here, without touching the machine

- `tests/unit/test_macos_apply.sh`: the account steps against a fake directory service (whole account;
  failed create leaves nothing; half-made account finished and keeps its number; missing home folder is
  not "done"; a foreign account is refused, and only noted while the switch is off); and, in a temporary
  folder with the running user as the principal, the **exact compiled grant and undo commands**: lists
  before equal lists after for every item that existed, a pre-existing entry for another principal
  survives, new files and folders created during the grant lose their inherited entries, a file moved in
  with no list does not break the undo, nothing is reached through a file link or a folder link, and
  the helper's `check` refuses a link, a missing folder, and an existing entry (and accepts its own with
  `--allow-own-entries`).
- `tests/unit/test_plan_engine.sh`: real apply on macos refused by default, refused for anything but
  `1`, refused without root, allowed with both, always allowed on a fake root; the linux refusal unchanged.
- `tests/unit/test_install.sh`: the macos plan applies on a fake root and records the account creation,
  the grants, and their sweep undos; the dry run says a real apply would be refused.
- Golden files: `install-macos-builder-tailscale-bb` and `install-macos-operator-cloudflare` changed
  (steps are no longer plan only); new `install-macos-builder-none` and `uninstall-macos-builder-none`.
  Linux and every `compile-*` and `revoke-*` golden are unchanged.

## What is still unverified (only a real install can show it)

- **`dscl` account creation.** Whether `createhomedir -c -u` works right after `dscl . -create` with
  no password; whether the directory service accepts our explicit generated identifier when it assigned
  none; whether `dscl -read ... Password` shows `*` for the account (the done check requires it, so a
  different display makes the step fail safe: it deletes the account and says so); whether `id -nG`
  answers right after creation.
- **Primary group 20 (staff).** The account is in staff, which is the existing design. Files that are group
  staff and group readable are readable by it. A dedicated group would be tighter; not changed here.
- **`sudo -u` into a hidden account** with `/bin/zsh`, and the account's access over remote login (still
  an owner step: add it to the remote login list by hand; the key is added by hand).
- **`chmod +a` on `/Users` and `/Users/Shared`** as root: whether the system allows it, and whether it
  survives; the check script reads both before and after.
- **The privacy protections of macos** (full disk access for the terminal running sudo) on the granted
  folder; the policy already refuses Desktop, Documents, and Downloads.
- **A volume without access list support** (some external drives): not checked. `chmod +a` would fail and
  the step with it.
- **A race on an intermediate folder.** `-h` protects the last path component only. A swapped
  intermediate folder is a remaining risk, as the linux notes in PERMISSIONS.md say; not run on a Mac.
- **A level change over a live grant** (observer, then builder, without an uninstall): not covered; the
  script uninstalls between levels.
- **Speed on a large tree.** The sweep reads lists in batches of 200 with `ls -ldef`; a tree with
  hundreds of thousands of items has not been timed.
- **`uninstall.sh` mode check on a record with a list.** `ls -ln` shows a `+` after the mode on a file
  with an access list; the code takes the first ten characters, so it should be fine, and the check script
  reads the record's mode itself.
- **`--allow-own-entries` sweeps hand-made entries.** On a re-run of an install this package made, the
  refusal for existing entries is skipped (they are the earlier run's). The uninstall sweeps every entry
  naming the service account, so an entry the owner added by hand for that account between runs is
  removed too.
- **Account numbers are reused.** `checkbuilder` gets the same number the deleted `checkobserver` had, so
  it owns `/Users/checkobserver`. The same will happen to a kept `/Users/agent` in production: a new
  service user can inherit an old home folder. Not addressed here.
- **Two identical sweeps at uninstall.** Each granted path has a file step and a folder step, and both
  record the same sweep as their undo (so a half-finished install still gets cleaned up). The second finds
  nothing, but the tree is walked twice.
- **Linux.** Everything added is also run in the linux test image (macos-only tests skip there); see the
  task comment for the numbers. No linux file or golden changed.
- Transports (Tailscale, Cloudflare), the kill switch, and rollback on macos are out of scope and stay
  plan only. Rollback is the only macos caller of `plan_access_control_remove_paths`, and its removal
  steps stay plan only, so a macos rollback is still refused as a whole.
