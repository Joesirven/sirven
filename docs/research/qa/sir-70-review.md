# SIR-70 code review: grant access model and snapshot undo

Reviewed `git diff a8c37e0...66e31fe` on this branch (5b8455b, 716fbc4, 66e31fe). Reviewed head: 66e31fe. Reviewer: quality control thread thr_cvq2422xsz, inline verification, real Linux container (Docker on the Mac, image `sirven-harness-linux`, repository mounted read only, no network). The installer was never run on the Mac itself. Probe scripts were scratch files outside the repository (`/tmp/sir70-probes`); nothing in product code was changed.

## Verdict: CHANGES REQUIRED

The new grant model for files created during the grant is sound: across folder modes 755, 750 and 700 and owner umasks 022 and 077, no new file or folder was readable by another account (details under Evidence). The undo is not safe. It reverts more than the grant added, it can be steered by the agent into changing ownership of any folder on the machine, and it silently loses lists on files with unusual names. All of these were reproduced for real. The harness cannot see them because every scenario leaves the machine untouched between install and uninstall.

## Must fix

1. **Undo restores every pre-existing path, not only paths that had extended lists, so it reverts the owner's changes and widens access.** `lib/access_control_snapshot.sh:30-36` (`_has_extended`). The patterns `*$'\n'user:?*:*` and `*$'\n'group:?*:*` use `*`, which in a shell pattern also matches newlines, so a block that holds only `user::rw-`, `group::r--` and `other::r--` still matches. Every recorded path is therefore handed to `setfacl --restore` (line 85), which puts back the old owner, group, mode bits and setuid or setgid flags.
   Reproduced (probe 1, 2 and 12): file `doc.txt` mode 644 in a granted 755 folder; the owner runs `chmod 600 doc.txt` during the grant; `neighbor` is denied (correct). After `uninstall.sh` (exit 0) the file is 644 and `neighbor` reads it. Root running `chown neighbor:neighbor f; chmod 600 f; chmod u+x f` during the grant is undone too (`700 neighbor:neighbor` became `640 owner:owner`). Special bits are cleared as well (probe 15): `chmod g+s,+t` on a folder and `chmod u+s` on a file during the grant came back as 755 and 644. The same applies to the pass-through parents, which are recorded alone: root ran `chmod 700 /srv` during the grant and uninstall put `/srv` back to 755. The design note in `docs/PERMISSIONS.md` and the commit message describe this as limited to "paths that had extended entries"; it is in fact every path that existed at grant time, and it includes folders such as a home folder that the owner hardened while the grant was in force. Rollback does the same during a live grant, reproduced in probe 15: builder grant, then a second install at observer level, the owner runs `chmod 600 g`, then `bin/sirven grant rollback` (exit 0): the file is 664 afterwards (644 plus the mask shown in the group position), so the world-readable bit the owner removed is back. Rolling back a level change therefore reverts the owner's permission edits since install. (A plain re-install at another level does not take a new snapshot and does not do this.)
   Fix: undo must remove only what the grant added. See "Recommended design" below. Minimum patch if the shell helper stays: anchor the test per line (`grep -Eq '^(default:|mask::|(user|group):[^:]+:)'` on the block), strip every `# owner:`, `# group:` and `# flags:` line from the block before `--restore`, and restore only the named and default entries, never the base entries. That still leaves item 2.

2. **The agent can make undo change ownership and mode of an arbitrary folder (privilege escalation).** `lib/access_control_snapshot.sh:42,53,85` (`[ -e "$path" ]` and `setfacl --restore` follow symbolic links, and the helper runs as root while the agent's processes are still alive). Reproduced (probe 6): builder grant on `/srv/work` (folder `sub/` with file `f`, owner `owner`). As `agent`, with only the access the grant gave it: `mv /srv/work/sub /srv/work/sub.old; ln -s /opt/victim /srv/work/sub`. `uninstall.sh` exits 0, and `/opt/victim` went from `root:root 700` to `owner:owner 755`, and `/opt/victim/f` from `root:root 600` to `owner:owner 644`. With `/etc` or any other target the agent gets a root-owned system folder handed to the folder owner, with the mode of the folder it replaced. Together with item 1 the primitive needs no planning: the path of every folder in the tree is in the snapshot. Order makes it worse: `pkill -KILL -u agent` runs in the user-removal step (`lib/service_user.sh:55`), after the access control undo, so the agent can also race the helper.
   Fix: never apply a restore by path. Do the removal and restore with file descriptors, one component at a time with `O_NOFOLLOW` (python3 is already a required dependency: `os.fwalk(..., follow_symlinks=False)` and `os.setxattr("/proc/self/fd/N", ...)`), refuse any recorded path whose parent chain is no longer the same folder (compare the recorded device and inode number), and never `chown` or `chmod`. Also run the access control undo after the agent's processes are killed and its account is locked (move the kill and `usermod -L` ahead of the access steps in the undo order), so nothing races the restore.

3. **While the grant is in force it widens access for another account when the tree already has named entries and a restrictive mask.** `lib/grant_compiler.py:330,336` (`setfacl -m` and `setfacl -R -P -m` recalculate the mask). Reproduced (probe 3): file `f` mode 644 with `user:bob:rw-` and `mask::r--` (bob effectively read only), folder `d` with `user:bob:rwx` and `mask::r-x`. After the builder grant, `bob` can append to `f` and create files in `d`; before the grant `bob` could not. Uninstall puts it back, so the exposure lasts for the life of the grant. The agent's write also needs the raised mask, so `-n` is not a fix on its own: on a file with no mask, `setfacl -n -m u:agent:rw-` creates the mask from the group bits and the agent stays read only (probe 14).
   Fix: before any change, `getfacl -R -P -s` (skip base-only entries) over each granted folder and parent. If any path has a named user or group entry or a mask that is narrower than a named entry, refuse that grant in the plan with a clear message ("<path> already has access lists for other accounts; granting would widen them"), or add a documented flag that accepts it. The same check covers the pass-through parents (`lib/grant_compiler.py:330`).

4. **Pre-existing lists on files with unusual names are silently destroyed by undo.** `lib/access_control_snapshot.sh:49` (`path="${line#\# file: }"`). `getfacl` escapes a newline as `\012` and a backslash as `\\` in the `# file:` line, so `-e "$path"` fails for those files, the block is dropped, and `setfacl -b` has already stripped the list. Reproduced (probe 4): nine files with a named entry for `bob`; files named `new<newline>line` and `back\slash` lost `user:bob:r--` and the mask after install then uninstall (exit 0, no warning). Spaces, quotes, tabs, `#` and non-ASCII names survived.
   Fix: do not round-trip through getfacl text. Record the raw `system.posix_acl_access` and `system.posix_acl_default` values (base64) next to the path encoded losslessly (JSON with `surrogateescape`, or hex), in the helper proposed under item 2.

5. **With a missing snapshot, uninstall reports success and leaves the original SIR-70 defect behind.** `lib/grant_compiler.py:318-325` (the undo check of the snapshot step is `[ ! -e <snapshot> ]`) and `lib/grant_compiler.py:269-282`. The check tests whether the snapshot file exists, not the state of the folder, so with the file gone the restore step is judged "already done" and skipped, and the helper's no-snapshot fallback is never reached through uninstall. Reproduced (probe 9, rerun with the output kept): delete `/var/lib/sirven/access-lists` after install, run uninstall: exit 0, "applied 11 steps, skipped 2 already done", and the plan shows both restore steps as `(already done)`. The folder keeps `default:user::rwx`, `default:user:owner:rwx`, `default:group::---`, `default:other::---`, `default:mask::rwx`, `user:1002:rwx` and a mask on every file, which is the defect the task was filed for. A damaged or truncated snapshot (`-s` false) would reach the fallback instead, and that fallback is also incomplete: `lib/access_control_snapshot.sh:73-78` removes only `u:agent`, never the folder owner's entry, the default list or the mask.
   Fix: make the undo check test the grant's own leftovers on the folder (any `user:<agent number>`, `default:` entry, or a mask with no named entry), not the snapshot file. Make the fallback remove what the grant adds (`setfacl -R -P -n -x` for the agent and the folder owner by number, `-k` for default lists, then collapse; record both numbers in the snapshot header, and read the agent's number before the account is removed). When the snapshot is missing the step must say so in the plan and the log instead of reporting done.
   Migration note: installs made before this change carry the old undo command text in their own install record (`setfacl -R -P -x u:agent` and `-d -x`), and uninstall runs that text, so those installs keep the original defect on undo whatever the new code does. A one-off repair command (remove the leftover default list, mask and owner entries) is worth shipping with the fix.

6. **A folder whose owner has no account name breaks the install halfway.** `lib/grant_compiler.py:339` (`$(stat -c %U ...)` prints `UNKNOWN` for a user number with no account, and `setfacl` rejects `u:UNKNOWN:rwX`). Reproduced (probe 11): `/srv/work` owned by user number 4242 with no passwd entry (a deleted account, a mounted volume, a lookup service that is down): install exits 4 at step 22 with `setfacl: Option -m: Invalid argument`. The recursive agent entry from step 21 stays in force, the default list is not set, so new files do not inherit the grant, and the plan said "applies". Fail-closed in the sense that nothing wider is created, but the user is left with a half grant.
   Fix: use `stat -c %u` and pass the number (`setfacl` accepts `u:4242:rwX`); make the check compare with `getfacl -n` (numeric) so name resolution never matters. Also skip the owner entry when the owner is root or the agent itself (probe 11 showed `default:user:root:rwx`, harmless but noise in every new file).

## Should fix

7. **Rollback and uninstall change owner-visible permissions in ways the plan does not announce.** `docs/PERMISSIONS.md` (snapshot and restore bullet) and `lib/access_control_snapshot.sh` header. After items 1 to 5 are fixed, the plan titles (`remove agent from ... and put back the access control lists it had`) are accurate; today they are not. Until then add a line to the printed plan and to `docs/PERMISSIONS.md` stating exactly which attributes undo touches.

8. **Files and folders the owner creates during a grant stay private after undo.** `docs/PERMISSIONS.md` already says new files are private; the new probe (8) shows what that means after uninstall: with umask 022 the owner's files created during the grant end as mode 600, folders as 755 with files inside 600, and `cp` copies are 660 during the grant. A web server or teammate who read by group or other can no longer read files made during the grant, permanently. This is the safe direction and fits the stated goal, but it is a behaviour change worth one sentence in the install summary, and the shared-folder case (a setgid folder with a group of collaborators) loses group sharing for every new file while the grant is in force. State both in `docs/PERMISSIONS.md` known limits.

9. **macOS: add `-h` to every `chmod +a` and `chmod -a`.** `lib/grant_compiler.py:285,291,298,359,367,373`. `find ... -exec chmod +a {} +` passes a path to `chmod`, which follows a symbolic link. `find -type f` is evaluated first, so a file swapped for a link between `find` and `chmod` (while the agent is live, for example during rollback's re-grant) gets an allow entry for the agent on whatever the link points at, such as `~/.ssh/id_ed25519`. This is reasoned from the code, not run (no Mac available), as is the claim below that inherited entries do not override the umask. Use `/bin/chmod -h +a` and `-h -a` (and `find -P`), or `find ... -exec` with the file-descriptor-safe helper. The rest of the macOS design is sound on the principles used here: named allow entries only, no base entries copied, inherited access control entries do not override the umask, undo removes by exact entry text rather than wiping the list. Known residual (already in the docs): `file_inherit` can give the agent execute on new files in an observer grant. It cannot run here; the manual check in `docs/PERMISSIONS.md` is adequate once it also says to compare `ls -le` of the parents (`/Users/you`).

10. **The snapshot holds the whole tree's lists.** `lib/access_control_snapshot.sh:67`. 30,201 paths gave a 2.6 MB snapshot and a 3 second uninstall (fine); a tree with a million files (node_modules, a build cache) will give a snapshot of hundreds of megabytes in `/var/lib`. Record only paths with extended entries (`getfacl -R -P -s`, or the xattr walk in item 2), which also removes the main reason item 1 matters.

11. **Add the missing harness scenarios** (they would have caught items 1 to 6): (a) owner and root change modes and ownership of pre-existing files and of the parent between install and uninstall; assert they are unchanged afterwards. (b) A file with a pre-existing named entry and a narrow mask; assert no other account gains access during the grant. (c) Odd file names (newline, backslash) with a pre-existing list; assert exact restore. (d) The agent replaces a folder with a symbolic link to a root-only folder; assert uninstall changes nothing outside the tree. (e) Snapshot deleted; assert the before and after diff is still empty. (f) `bin/sirven grant rollback` for real (below). (g) A folder owned by a number with no account name. (h) A second install that adds a nested path (it worked in probe 5, keep it as a regression guard).

## Nice to have

12. `lib/access_control_snapshot.sh:62` creates the snapshot folder with `mkdir -p` under the caller's umask (it came out 755 inside the 700 `/var/lib/sirven`, so it is not exposed). Create it with `install -d -m 0700` so it does not depend on the parent.
13. `lib/access_control_snapshot.sh` header says restore "is idempotent"; with no snapshot a second run is a no-op, with one it removes the snapshot, so also true. Add a unit test for the helper itself (it has none; `tests/unit` only checks generated text, `tests/unit/test_uninstall.sh:35`, `test_cli.sh:115`).
14. `shellcheck` is not installed on this Mac, so `make lint` checked syntax only; the new helper's `FLAGS` quoting and `local` use were not linted. Run `docker run --rm -v "$PWD":/mnt koalaman/shellcheck:stable lib/*.sh` once in the continuous integration job.
15. The pinned-copy helper path comes from `/var/lib/<package>/package/lib/...`. If the helper is renamed to Python for item 2, keep the shell entry name so installed records written by this commit still work (the record stores the command text).

## Judgement on the stated trade-off (item 3 of the brief)

Not acceptable as built. The implementer described a narrow side effect ("undo also reverts the owner's own permission changes to pre-existing files"). The real effect is wider: owner, group, mode, setuid and setgid of every path in the tree and of every pass-through parent, and, through path-following, of whatever an agent points a link at. A permission undo must do the reverse of what the grant added and nothing else; the Linux grant adds named entries, a default list, and a mask, and nothing in the base entries, so the exact undo is also the simplest.

### Recommended design (one helper, python3, file descriptors)

- **Record** (`record FOLDER recursive`): walk with `os.fwalk(follow_symlinks=False)`. For each non-link path that has `system.posix_acl_access` with named entries, or any `system.posix_acl_default`, store `{path (lossless), dev, ino, access (base64), default (base64)}`. Also store the numbers of the agent and the folder owner. File mode 0600, folder 0700.
- **Restore**: walk again the same way. For every path: remove named entries for the stored agent and owner numbers (mask kept, the effect of `setfacl -n -x`); on folders remove the default list; then, if a stored entry exists for the same device and inode, put back its named and default entries only; then, if no named entry remains, collapse to a plain mode: group bits become the group entry AND the mask, the mask entry is dropped (this is what keeps the owner's later `chmod 600`). No `chown`, no `chmod` of the owner or other bits, no restore by path.
- Prototype check (probe 13, not product code; it uses the command line tools): grant, owner `chmod 600 doc.txt`, new file created, then this undo. Result: `doc.txt` stays 600, `sub/keep` back to 644 with an identical list, the new file is plain 600, the folder lists identical to before install, with one remaining difference (a `mask::r-x` on the pass-through parent `/srv`, which the prototype did not collapse; the real helper must collapse parents too).
- Rollback and the kill switch call the same helper, so their behaviour follows.

## Evidence

All probes ran in fresh containers: `docker run --rm --network none --memory 256m --pids-limit 256 -v <repository>:/src:ro ...`, one scenario per container, nothing kept. Exit statuses below are those printed by the container.

**Gates (foreground, this Mac).**
- `bash tests/harness/run-linux.sh`: exit 0. 5 scenarios, 0 failed; scenario 03 has 4 known defects (all SIR-32, kill switch not built). Scenarios 01, 02, 04 and 05 pass (21, 9, 10, 3 passed).
- `make test`: exit 2, 438 passed, 3 failed: `test_install_started_by_sh_says_to_use_bash`, `test_enter_twice_accepts_the_shown_defaults`, `test_input_that_ends_takes_the_defaults`. These are the 3 known macOS installer failures; nothing else fails.
- `make lint`: exit 0 (`bash -n` on 64 files; the shell linter is not installed, so that part was skipped).

**Check 1: widening paths.**
- New files and folders, matrix of folder mode (755, 750, 700) by owner umask (022, 077), probe 8: the owner created a file, a folder with a nested file, a three-level nested folder, a `cp`, a `cp -p`, a `cp -a`, a file moved in with `mv`, and a file under `umask 077`. In all six cases the files made by plain creation or `cp` were unreadable for `neighbor` and for a member of the folder's group (`devmate`); the nested folders were not enterable by them. The only files they could read were ones whose owner-set mode was deliberately open (`cp -p` of a 644 file, a file moved in as 644, and the pre-existing 644 file in a 755 folder), which is the owner's own action and the same as without the grant. No widening found for new content.
- Pre-existing named entries with a narrow mask: widened while the grant is active (must fix 3).
- Pass-through parent: `chmod 700 /srv` by root during the grant was reverted to 755 by undo (must fix 1). The mask shown by `stat` on parents and files is not a grant to the group; `getfacl` shows `group::---`.
- Symbolic links: `setfacl -R -P` and `getfacl -R -P` skip links in the walk (correct), but `setfacl --restore` and `[ -e ]` follow them (must fix 2). A link as the granted path itself was not tested; `-P` skips links on the command line.
- Files moved in from elsewhere keep their own mode and get no entry for the agent (not widened, but the agent cannot read a moved-in private file; documented behaviour of inheritance).

**Check 2: snapshot safety.**
- Stored in `/var/lib/sirven/access-lists/<first 16 hex of sha256 of the path>.txt`, mode 600 root; the folder `/var/lib/sirven` is 700 (the `access-lists` folder itself came out 755 under a 022 umask, covered by the 700 parent; nice to have 12).
- Missing snapshot: uninstall skips the restore step as already done, exits 0 and leaves the original defect (must fix 5). Tampering needs root; with root-edited content a block for `/opt/other` plus `# owner: neighbor` changed `/opt/other` to `777 neighbor:neighbor` (probe 9b), which shows the file is trusted for any path it names. Restrict each recorded path to the granted folder (a path-prefix test) once the helper is rewritten.
- Path deleted during the grant: skipped, exit 0 (scenario 05 passes). Path replaced by a link: followed (must fix 2).
- Size: 30,201 paths, snapshot 2.6 MB, install 1 second, uninstall 3 seconds (probe 10).
- Names: spaces, quotes, tab, `#`, non-ASCII survive; newline and backslash do not (must fix 4).
- Nested grants (probe 5): installing `/srv/work` then adding `/srv/work/sub` in a second install, then uninstall: lists identical to before.

**Check 4: rollback for real (probe 7, builder then observer on `/srv/work`, then `bin/sirven grant rollback`).** The harness can run it, no change to the harness is needed beyond a scenario file. Results: `--dry-run` printed a 9-step plan (restore, re-snapshot, re-grant); the real run exited 0 ("applied 9 steps"); the lists afterwards were identical to the builder state before the level change; the agent could write again; a second rollback exited 0; uninstall then left the machine lists identical to the state before the first install. So the happy path works; the owner-attribute revert (must fix 1) also applies to it. The kill switch (`install.sh revoke --all`) cannot be run for real: it exits 3 "not yet" (SIR-32), so its restore lines are plan text only.

**Check 5: macOS.** Read `lib/grant_compiler.py:282-376` and the level files. Judgement in should fix 9. Not run (cannot run here).

**What I could not check.** Only Linux with the `acl` package version in Debian 12 slim; a filesystem without access list support (the grant would fail at the first `setfacl`); the real second host Omashu or ba-sing-se; the macOS steps.

## Result

CHANGES REQUIRED. Fix 1 to 6 (1 and 2 first; 3 and 5 follow from the same helper rewrite), add the scenarios in item 11, then re-review with the same probes (kept as scratch; I can add them to `tests/harness/scenarios/linux/` as the new scenarios on request).

Reviewed head: 66e31fe on branch `code-review-grant-access-model-and-snapshot-undo-thr_cvq2422xsz`. This file is added by the commit above it on the same branch (a file cannot name its own commit; see `git log -1 -- docs/research/qa/sir-70-review.md`).

---

# Re-review of round 2 (branch `sir-70-round-2-safe-undo-no-link-following-refus-thr_e75v2he8zw`, tip 1ce7450)

Reviewer: the same quality control thread. Method as before: fresh containers (read-only repository, no network, 256 MB), one scenario per container, plus one image with an ssh server added (`sir70-sshd`, 156 MB, built from the harness image) and, for filesystems, a throwaway named volume, a tmpfs, and a folder shared from the Mac. The installer was not run on the Mac. Probe scripts are scratch files in `/tmp/sir70-probes` (not committed).

## Verdict: CHANGES REQUIRED (two small must-fix items)

Round 2 fixes every round 1 finding I reproduced. The new helper is well built: its grant and undo matched `setfacl` exactly in a randomised comparison, and I could not make it follow a link. Two new problems remain, both let the unprivileged agent obstruct the owner reducing or removing its access. Neither widens access, and the agent's account is locked while they happen, but the brief asks for a strict standard on the core permission model.

## Round 1 findings, re-run

| Round 1 item | Round 2 result (probe) |
|---|---|
| 1 undo reverts owner, group, mode of pre-existing paths | Fixed. Owner `chmod 600` stays 600 after uninstall; root `chmod 700 /srv` on the pass-through parent stays 700; `chmod g+s,+t` on a folder and `u+s` on a file stay (3755, 4644); rollback after an owner `chmod 600` leaves group and other empty (effective). (p1, p12, p15) |
| 2 agent link swap makes undo change `/opt/victim` | Fixed. `/opt/victim` stays `root:root 700`, its file `root 600`; undo prints "was a folder when the grant was made and is now a symbolic link; the link was not followed". (p6) |
| 3 widening on a tree with a named entry and a narrow mask | Fixed by refusal: install exits 2 "refusing this grant ... nothing was changed", and `bob` stays read only. But the refusal itself has a new problem, see must fix A. (p3) |
| 4 lists lost on odd file names | Fixed. The old probe now stops at the refusal (its files carry a named entry for `bob`). A new probe (q12) uses folders named with a newline, a backslash and a space, each with a base-only default list set by the owner, a file inside, install, a folder with a newline name made by the agent, uninstall: `getfacl -R -p` before and after identical (this also covers the one restore path the randomised comparison did not: earlier default lists). (p4, q12, scenario 09) |
| 5 missing snapshot leaves the original defect | Fixed. Undo no longer treats a missing snapshot as done; it removes the grant's entries, warns, and writes an audit warning; the lists are identical to before install. Older installs: see should fix 4. (p9c) |
| 6 owner with no account name fails the install | Fixed. Folder owned by user number 4242: install exits 0, `default:user:4242:rwx`; a root-owned folder gets no owner entry. (p11) |

## Must fix

A. **The agent can block lowering or rolling back its own access.** `lib/access_control.sh:120-146` (`access_control_refuse_existing_lists`) runs in every plan that grants, including a re-install at another level and `bin/sirven grant rollback`, and `lib/access_control_snapshot.py:234-248` (`problems_in`) counts any named entry of another account, on any path. The agent owns the files it creates, so it can add such an entry itself. Reproduced twice (q4, q4b): builder grant on `/srv/work`; as `agent`: `echo x > /srv/work/mine; setfacl -m u:neighbor:r /srv/work/mine`. Then (1) `install.sh --level observer` exits 2, "refusing this grant ... /srv/work/mine (access list has an entry for user 1001 (neighbor))"; (2) after observer then builder, `bin/sirven grant rollback` exits 2 with the same text, and the agent can still write ("yes-STILL-BUILDER"). Uninstall still works, so this is not a lock-in, but the owner cannot step the agent down, which is the main use of a level change and of rollback. A legitimate owner edit (`setfacl -m u:bob:r file` during the grant) triggers it the same way.
   Fix: refuse only when granting would actually widen someone, which is exact and cheap: compute the new mask (union of the group entry, the agent and the other named entries, as `mask_of` does) and refuse only if a named entry of another account, or the group entry, has permission bits outside the current mask, on a path not owned by the agent. A lower level, or the same level again, never raises the mask, so it passes; a rollback that re-grants a higher level after the owner narrowed a mask is still refused, so the check must keep running for rollback (no exemption). The group entry matters because a mask narrower than `group::` is exactly the leftover state of the original defect. Also change the refusal text: `setfacl -R -b FOLDER` (line 142) strips every list including the ones other accounts rely on and the agent's own; say "remove the named entry with `setfacl -x u:NAME PATH` for the paths listed".

B. **A deep folder tree made by the agent breaks undo.** `lib/access_control_snapshot.py:121-167` (`walk`) is recursive and holds one open descriptor per level; `main` sets `sys.setrecursionlimit(10000)` (line 723) and catches only `OSError`, `Failure` and `CalledProcessError`. Reproduced (q3, q3b): as `agent`, a chain of 12,000 folders (`os.mkdir('d'); os.chdir('d')` repeated; cheap, relative paths avoid the path length limit). `uninstall.sh` exits 4 with a raw `RecursionError` traceback; step "put back the access control lists" failed; the agent's account stays locked and expired, its entries stay on the files, two snapshot files stay. The owner can recover by deleting the tree (`rm -r` handles any depth) and running uninstall again (exit 0, agent removed, verified), but nothing says so. Measured separately (q3c): with the container's default open-file limit a chain of 1,100 levels undoes fine, but with `docker run --ulimit nofile=1024:1024` (the usual soft limit of a login shell) the same 1,100-level chain makes uninstall exit 4 with `error: /srv/work/deep/d/d/.../d: cannot list: Too many open files`, and the account stays locked (`!*`, expiry day 1). So the failure needs only about 1,000 levels on a host with a 1,024 limit, not 12,000.
   Fix: make `walk` iterative, close each folder's descriptor once its names are read and reopen children by name from a saved parent descriptor chain only as deep as needed (or reopen from the start folder by relative components), raise the soft descriptor limit to the hard limit at start, and turn any remaining exception into an `error:` line with a one-sentence recovery hint, not a traceback. A path deeper than a fixed bound (say 4,000 levels) should be reported by name and skipped, with the rest of the undo continuing.

## Should fix

1. **Re-run after a crash leaves the account expired.** `lib/grant_compiler.py:389-399`: the "give agent its account back" step has the same check as the grants (`everything_in_place`). If the install stops after the last grant and before that step, a re-run judges both quiesce and release "already done" and never releases (q5: after a simulated crash and a same-level re-run the account stays `agent:*:1`, expired, with the marker file still present; a later level change releases it). Fail-closed, but unexplained. Make the release check "the marker file does not exist".
2. **A failed install leaves the account locked and expired and does not say so.** (q6 with a read-only mounted subfolder, and the unsupported file system runs) the message is "steps before it stay applied; fix the cause and run again". Add a line: "the account agent is locked and expired until a run finishes; re-run to release it".
3. **One `pkill` pass does not end a process that keeps forking.** `lib/access_control_snapshot.py:434`. An agent process survived the pass in 4 of 6 tries (q10: a shell loop starting a `sleep` every 5 ms; I counted survivors, not which process). The descriptor-based walk does not depend on it, and the account is locked and expired, but the plan promises "end every process". Loop `pkill -KILL` until `pgrep -u` is empty, at most 20 times, then fail with a message.
4. **A partial recursive grant is judged done on a re-run.** The grant-access check (`lib/grant_compiler.py:~367`) looks only at the start folder. If one path fails (read-only subfolder, q6: install exits 4, retry prints "22. skipped, already done" and fails at the next step), the rest of the tree is silently not covered on a retry that gets past that step. This is the narrow direction, not a widening. Fix: the check should use the helper's read-only `status` over the tree, or the step should always run (it is idempotent).
5. **Repair needs the account to still exist.** After an old uninstall the account is gone, so `repair` exits 1 "the account agent is gone and no snapshot names its number" (q9) and the default list and masks that the old uninstall left stay. The documented order (repair before uninstall) works and restores the exact lists (q9b), and the documentation says the alpha cut runs only in throwaway containers, so this is low priority; but a machine like the one the task came from is in exactly this state. Add `repair --leftovers FOLDER` that removes a default list or a mask that has no named entry, after printing what it will remove.
6. A new `install.sh` over an old install is refused ("what is already on this machine conflicts", nothing changed, exit 2), so an old install cannot be upgraded in place; uninstall (after repair) then install is the path. Say so in the documentation's "installs made before this change" paragraph.

## Nice to have

7. Hard links: the grant and undo walk by inode, so a hard link the agent plants in the tree to a root-only file would get the agent's entry on a re-grant. `fs.protected_hardlinks=1` (default on current distributions; it is 1 in the test machine, and `ln` failed with "Operation not permitted", q11) prevents the agent making that link. Have the preflight warn when the sysctl is 0.
8. `lib/access_control_snapshot.py` `undo_default` drops the whole default list when it carries the agent's entry, which also removes a default entry the owner added by hand during the grant (narrow direction). Remove only the agent's and the owner's entries and the group and other `---` base entries, when the snapshot has no earlier default list.
9. On a file system without access lists the install says `Operation not supported` for each path (tmpfs and the Mac file share, q8). Add one sentence: "this file system does not support access lists".
10. Documentation: the chmod exception should also name this result: a file the owner makes `644` during the grant ends `604` (other keeps read, the group part drops to the group entry and mask, so the group gets nothing). It is the narrow direction and matches the stated exception.
11. Harness: add the two scenarios that would have caught A and B (agent-made named entry then a level change and rollback; a 12,000-level chain then uninstall and a re-run), add `openssh-server` to `Dockerfile.linux` (about 11 MB) so the lock-and-expire claim has a permanent test, and a scenario for the crash between quiesce and release.
12. `shellcheck` is still not installed on this Mac (`make lint` checks syntax only); the shell parts changed by round 2 are small, so this is unchanged.

## Evidence

**Gates, foreground, on 1ce7450 (scratch worktree `/tmp/sir70-r2`).**
- `bash tests/harness/run-linux.sh`: exit 0; 15 scenarios, 0 failed; the only known defects are the 4 in scenario 03 (SIR-32).
- `make test`: exit 2; 446 passed, 3 failed: `test_install_started_by_sh_says_to_use_bash`, `test_enter_twice_accepts_the_shown_defaults`, `test_input_that_ends_takes_the_defaults` (the 3 known macOS installer failures).
- `make lint`: exit 0 (`bash -n` on 65 files; shellcheck not installed).

**Binary list format and mode collapse.** The grant side is compared with `setfacl`; the undo side is checked against the helper's own stated rule (computed from `getfacl` before undo), not against another tool. A randomised comparison in a container (`fuzz.py`, seeds 1 to 6, 12 trees per seed, about 60 entries each: files and folders with modes from 000 to 4755 and 2775, owners `root` and a numbered owner, grants `r`, `rw`, `rX`, `rwX`, `rwx`, `x` on pass-through parents):
- Grant parity: the helper's `grant-access` and `grant-default` gave a `getfacl -R -P -p -n` listing identical to `setfacl -R -P -m u:agent:SPEC` plus `setfacl -R -P -d -m g::---,o::---,u:agent:SPEC,u:OWNER:SPEC`, in all 72 trees, and for a second grant at a different permission set (a level change) in all 36 trees of seeds 4 to 6; pass-through parents identical to `setfacl -m u:agent:x`.
- Undo: after random `chmod` of about a third of the paths during the grant, and files created under umask 022 and 077, then `restore` from a snapshot (seeds 1 to 6; seed 1 was also run with `repair`): owner and other bits and special bits unchanged, group bits equal to the group entry AND the mask taken from `getfacl` before undo, no named, mask or default entry left, on about 2,400 paths. Zero mismatches. The kernel accepted every attribute the helper wrote (it validates the order and format).
- Round 1 equivalents: pass-through parent hardening, special bits, rollback after owner edits (above).

**Errors mid-tree, partial undo, locked account.** Install into a folder holding a read-only mounted subfolder (q6): the walk reports `error: /srv/work/ro: Read-only file system`, still visits every other path, exit 4, step named in the message; the account is `!*` with expiry day 1 afterwards (locked); uninstall afterwards exits 0 and the lists match the machine before install. Deep tree (must fix B): step failure, account stays locked, rerun after removing the tree succeeds.

**Races.** The helper opens every component with `O_NOFOLLOW` from a descriptor and edits the open descriptor, so a swap cannot redirect it by construction. Empirical: an agent process swapped folders and 400 files with links to a root-only folder and file in a loop (q2: 25 grants, 25 repairs; q2b: 6,000 names, 139,000 swaps, 40 grants and repairs): the root-only folder and file were unchanged, including with an entry for the agent deliberately placed on them to expose a followed link. The helper printed no message about a swap in either run, so I cannot say how often the window was actually hit; treat this as supporting evidence, the guarantee comes from the design. The permanently planted link (round 1 attack) is skipped with a warning.

**Account lock and restore (s1, real `sshd` 9.2 in a container, key login for `agent`).** Baseline login works. After `quiesce` (locked, expiry day 1) a key login fails with `UsePAM yes` ("Connection closed") and with `UsePAM no` ("Permission denied"); after `release` the login works again with both settings. An account that was already locked stays locked after release. An account with an expiry date (2030-01-01) gets it back exactly. Separately (s2): with `UsePAM yes` (the usual setting) a lock alone does NOT stop key login (`LOGIN-OK` with only `!` in the password field) and expiry alone does; with `UsePAM no` either one stops it. So the expiry is the part that matters, and the helper sets both.

**Large trees.** 301,001 entries (100,000 folders, 200,000 files): install 10.8 s, snapshot 7.8 MB, helper peak memory about 100 MB during uninstall (4.4 s). Round 1 numbers (30,000 entries) are faster still.

**File systems.** ext4 (Docker volume) and overlay: grant and undo identical to before. tmpfs and the Mac file share in this Docker engine do not support access lists: install exits 4 with `Operation not supported` per path, nothing widened, uninstall exits 0 with the lists unchanged. A loop-mounted ext4 or xfs image needs extra privileges that the harness rightly does not give, so I did not try them; xfs, btrfs, NFS and big-endian machines were not tested (the attribute is little-endian by definition).

**Repair and older installs (q9, q9b, with the real a8c37e0 package).** Repair before the old uninstall (the documented order) gives lists identical to before the old install, exit 0 both for the folder and the parent. After the old uninstall, repair cannot run (should fix 5). A new install over an old one is refused (should fix 6).

**macOS (read only).** `chmod -h`, `find -P` in `lib/grant_compiler.py` are the right fix for the link race I raised; the shell test strings were updated. Still not run on a Mac.

## Result

CHANGES REQUIRED. Fix A and B (both small and local), then re-verify with the two new scenarios; the should-fix items can follow. After that I would approve: the design, the helper and the evidence for the rest are good.

Reviewed head: 1ce7450 (branch `sir-70-round-2-safe-undo-no-link-following-refus-thr_e75v2he8zw`). Commit adding this section: see `git log -1 -- docs/research/qa/sir-70-review.md` on branch `code-review-grant-access-model-and-snapshot-undo-thr_cvq2422xsz`.

---

# Re-review 3 (branch `sir-70-round-2-safe-undo-no-link-following-refus-thr_e75v2he8zw`, tip 2211d8f)

Same method (fresh containers, scratch worktrees of 2211d8f and of a8c37e0 for the old-install tests). Probe scripts stay in `/tmp/sir70-probes`.

## Verdict: CHANGES REQUIRED (two new must-fix items, both small)

Must-fix A and the descriptor and recursion part of B are fixed, and five of the six should-fix items are fixed (item 5, repair after the account is gone, only partly: see should fix 1). Two new problems turned up in the rewritten walk.

## Gates, foreground, on 2211d8f
- `bash tests/harness/run-linux.sh`: exit 0; 21 scenarios, 0 failed; the only known defects are the 4 in scenario 03 (SIR-32).
- `make test`: exit 2; 450 passed, 3 failed: the 3 known macOS installer tests.
- `make lint`: exit 0 (`bash -n` on 65 files; shellcheck not installed).

## Must fix

C. **Memory grows with the square of the depth, so the agent can exhaust memory in root's helper.** `lib/access_control_snapshot.py:201` (`child = top.path.rstrip(b"/") + b"/" + raw`) and `Frame.path`: every open frame keeps its full path. Measured on `restore` (q14, a chain the agent builds with relative `mkdir` and `chdir`, names of 255 characters): 1,000 levels = 171 MB peak memory, 2,000 levels = 546 MB, so about 2 GB at 4,000 and 8 GB at 8,000. With two-character names, 31,000 levels was killed by the out-of-memory killer in a 256 MB container (helper exit 137, no message; uninstall exit 4 with only "step 2 failed"). The install-time check uses the same walk, and it fails the same way: with a 2,000-level chain of 255-character names and a 512 MB limit, `install.sh --level observer` exits 2 with "the access lists on the granted folders could not be checked, so the grant is refused" (q19), so the agent also blocks a step-down again, until the tree is removed (fail closed, but it is the obstruction that must-fix A was about). On a low-memory host the killer may pick another process. Fix: do not store a path per frame. Keep only the name chain (the names are already in `Frame.name`) and build a path string only when printing an error or warning; pass `visit` the last name and the parent identity (`record()` already uses only the last component). Also do not keep `Frame.names` (the folder's whole listing) for a frame whose descriptor was let go: re-read the listing, or keep only a position and re-list, when the frame is reopened. Measured (q18): 3,000 levels with short folder names and 300 files of about 245 characters per level (900,000 files) made `restore` peak at 298 MB, from the held listings alone. Add a harness scenario: 3,000 levels of 255-character folder names, and another with many long-named files per level, each asserting peak memory under 100 MB and exit 0. The baseline the fix must keep: a tree of 301,001 entries gave install 11.6 s and 60 MB, uninstall 4.2 s and 87 MB (q7, on 2211d8f). Re-test the 31,000-level case afterwards: the intended "deeper than 30000 levels ... remove that folder" message could not be observed because the helper died first.

D. **A subtree moved while the walk is deep is skipped without any error (a revocation gap for rollback).** `lib/access_control_snapshot.py:179-183`: when a folder let go of (more than 48 levels up) cannot be reopened, its frame is popped with only a comment, and the names not yet read in it are never visited. Reproduced deterministically, end to end (q15, q15b; the "agent" is a hook on the folder listing, so the timing is exact): a 60-level chain with 20 files beside it, the real `grant-access` run first so every file holds the agent's entry; while `repair` is listing level 60, the chain's first folder is renamed out and its parent is renamed. `repair` exits 0 and `getfacl` still shows the agent's entry on 20 of 20 files. Two controls: renaming only the chain's first folder gives exit 0 and 0 of 20 left (the `..` reopen works); swapping a folder 20 levels down for a link to a root-only folder gives exit 0, 0 of 20 left, and the root-only folder unchanged. Only an un-quiesced undo can be raced this way, and rollback is that. Shown with `bin/sirven grant rollback --dry-run` (q17): after a single install (previous level none) the plan is 3 steps and holds no "end every process" step at all; after observer then builder the plan puts the two restore steps (1 and 2) first and the "end every process of agent" step only at step 5, after them. So for a rollback to no grant, an agent that keeps swapping two renames can leave `user:agent` entries on the skipped files. Fix: append an error for every frame dropped this way ("moved while it was being read: N names not visited") so the step fails and the owner reruns; and quiesce the agent (end its processes, lock and expire the account, release afterwards) at the start of the rollback removal exactly as uninstall does. (Uninstall, and a rollback that re-grants, are already quiesced, so the race does not reach them.)

## Should fix
1. **Repair when the account is already gone leaves the default list.** (q16 case 3, old package: install, old uninstall, then `lib/access_control_snapshot.sh repair`.) The masks are removed, but the folders keep `default:user::rwx`, `default:group::r-x`, `default:mask::r-x`, `default:other::r-x` (12 leftover lines before repair, 8 after), which still override the umask for new files, the original defect. `sirven grant repair` also stops at "no grant record" there. The alpha cut runs only in containers, so this is low priority; a `--leftovers` flag that removes a default list with no named entry, after printing it, would finish it.
2. **Pre-existing named entries: the mask comes back wider than before.** (r1) A file with `user:bob:r--` and `mask::r--`, after install and uninstall, has `mask::rw-` (and its group entry narrowed to the old effective value). No account can do more than before (bob stays read only; I checked), but `stat` now shows the group write bit, which audit tools and `StrictModes` read. Restore the recorded mask when the snapshot has one.

## The group-entry deviation in A (judged)
Accepted. The grant clears the bits that the current narrow mask had switched off on the group entry and on other accounts' entries, then raises the mask, so no account can do more than before; the stored group entry becomes narrower, which is the safe direction and only changes what `getfacl` prints. Evidence: (1) a random comparison (fuzz2: 400 files and folders with random modes, a named user and a named group with random permissions, random masks, random later `chmod`, grants of `r`, `rX`, `rw`, `rwX`, `rwx`): the effective permissions of the owner, group, named user, named group and other were never wider afterwards (0 of 400; my first version of this check skipped the narrowed entries and was wrong, I fixed it and re-ran). (2) A file with group `rw-` narrowed to `r--` by the mask: after the grant a member of the group still could not write. (3) The refusal still applies to a named entry of another account or group that has bits outside the mask, so nothing is silently cut. One consequence: a refused tree must be edited by the owner by hand; the new message gives the exact `setfacl -x` command.

## Spot checks that passed
- **A (agent blocks a step-down):** with `setfacl -m u:neighbor:r` on the agent's own file, `install.sh --level observer` exits 0 and `bin/sirven grant rollback` exits 0, and afterwards the agent cannot write (q4, q4b). An owner-made entry inside the mask passes; one outside the mask is refused with the entry named and the fix printed (r1).
- **B (depth):** 12,000 levels with an open-file limit of 256: level change exit 0 and uninstall exit 0; a count by descriptor shows every one of 12,001 levels had the agent's access and default entries before and none after; 1,100 levels with a limit of 1,024: uninstall exit 0; no traceback (q13, q3, q3c, q3b). Beyond 30,000 levels see C.
- **Forking agent:** 0 survivors after quiesce in 6 of 6 tries (it was 4 of 6 in round 2; q10).
- **Link swaps and moves:** the swap loops (q2, q2b) are only one or two levels deep, so they never reached the reopen code (it runs for folders let go more than 48 levels up); they only show the shallow walk is still safe (root-only folder and file unchanged). The deep cases were run with the exact-timing hook (q15b, see D): a single rename of the chain's first folder is followed correctly through `..` (all 20 siblings visited, exit 0); a link swapped in for a folder 20 levels down is not followed (root-only folder unchanged, exit 0); the two-rename case is the failure in D.
- **Release check:** after a simulated crash between quiesce and release, a same-level re-run now plans "give agent its account back (to do)", releases the account and removes the marker (q5).
- **Failed install message:** says the account is locked and expired, how to finish, and the `release` command (q6); a retry fails again at the same step instead of skipping it (the whole-tree check works, no silent partial grant).
- **Upgrade and repair, with the real a8c37e0 package (q16):** a new install over an old one is refused with the three steps printed; `sirven grant repair` (with `--dry-run` first), the old uninstall, then the new install, then the new uninstall: lists identical to before at every point.
- **Large trees (the walk was rewritten, so re-measured):** 301,001 entries: install 11.6 s and 60 MB, uninstall 4.2 s and 87 MB (round 2: 10.8 s and 4.4 s).
- **Not re-tested this round:** the lock and expiry against a real sshd (the diff of `command_quiesce` changes only the kill loop; the `usermod` lines are unchanged), file systems other than overlay, macOS (read only).

## Result

CHANGES REQUIRED: fix C and D (both local to `walk`, plus one added step in rollback), add the two scenarios, then I would approve.

Reviewed head: 2211d8f. Commit adding this section: see `git log -1 -- docs/research/qa/sir-70-review.md` on branch `code-review-grant-access-model-and-snapshot-undo-thr_cvq2422xsz`.

---

# Re-review 4 (branch `sir-70-round-2-safe-undo-no-link-following-refus-thr_e75v2he8zw`, tip b9e1b21)

Same method (fresh containers, scratch worktrees of b9e1b21, 2211d8f and a8c37e0). Probe scripts stay in `/tmp/sir70-probes`.

## Verdict: CHANGES REQUIRED (one small must-fix, E; otherwise ready to approve)

Both round 3 must-fix items are fixed and I could not break the fixes. One agent-controlled memory cost remains (E): linear in the number of folders, not in depth. I first filed it as a should-fix, then timed it and reclassified it, for the same reason C was a must-fix.

## Gates, foreground, on b9e1b21
- `bash tests/harness/run-linux.sh`: exit 0; 26 scenarios, 0 failed; the only known defects are the 4 in scenario 03 (SIR-32).
- `make test`: exit 2; 452 passed, 3 failed: the 3 known macOS installer tests.
- `make lint`: exit 0 (`bash -n` on 65 files; shellcheck not installed).

## Must fix C (walk memory): fixed
Same chains and commands as round 3, peak memory of `restore`:

| Case | 2211d8f | b9e1b21 |
|---|---|---|
| 1,000 levels, 255-character names | 171 MB | 14 MB |
| 2,000 levels | 546 MB | 15 MB |
| 3,000 levels | about 1.2 GB (extrapolated; not run) | 15 MB |
| 3,000 levels, 300 files of about 245 characters per level (900,000 files) | 298 MB | 18 MB |
| install-time check, 3,000-level chain of 255-character names, 512 MB limit | refused ("could not be checked") at 2,000 levels | level change exit 0 |

Depth: 12,000 levels with an open-file limit of 256: level change and uninstall exit 0 and every one of the 12,001 levels is clean afterwards. 31,000 levels: level change refused (fail closed), uninstall exits 4 with `error: ...: deeper than 30000 levels, so it and everything in it was skipped. remove that folder (rm -r) and run the same command again`, the path printed shortened to its two ends (59,712 bytes noted), the first 30,000 levels cleaned, account locked (this was an out-of-memory kill with no message in round 3). Large-tree baseline kept: 301,001 entries, install 11.4 s and 61 MB, uninstall 4.3 s and 87 MB (round 3: 11.6 s, 60 MB, 4.2 s, 87 MB).

## Must fix D (a folder lost mid-walk, and rollback with a live agent): fixed
- Exact-timing hook at level 60 (q15b, end to end: real `grant-access`, then `repair`, with the chain's first folder and its parent renamed while the walk is 60 levels down): `repair` now exits 1 (it was 0) and prints `error: /srv/t/a: moved, replaced or removed while it was being read, so the names still to be read in it were not visited. run the same command again`, then the recovery text. Immediately afterwards the 20 files still hold the entry (20 of 20); `repair` run again without the hook exits 0 and leaves 0 of 20 (q15c). So: loud, not silent, and the rerun finishes the job. The two controls are unchanged (single rename: all 20 visited, exit 0; link swapped in for a folder 20 levels down: not followed, root-only folder unchanged, exit 0).
- Rollback plans (`bin/sirven grant rollback --dry-run`, q17): after a single install, 5 steps: end every process and lock the account (1), the two restores (2, 3), remove the grant record (4), give the account back (5). After observer then builder, 13 steps: the same quiesce first and restores, then the re-grant with its own quiesce, and the release twice at the end (the second is a no-op because the marker is gone).
- Real runs (q20, q21) with a live `sleep` process of the agent and an expiry date set on the account (2031-01-01): rollback to no grant exits 0, the process is gone, the account is back as it was (`*`, expiry kept), the marker file is gone, no numbered user entry and no default list or mask is left anywhere under `/srv`. Rollback to the observer level: same, and the agent then reads but cannot write. A rollback that fails midway (a chain beyond the depth bound) exits 4, leaves the account locked and expired with the marker present, prints the reason, the path shortened, and how to finish or release; after the owner removes the chain, the same command exits 0 and the account is `agent:*:` again.

## Completeness of the re-list path (the new code that resumes a folder after it is reopened)
Memory was measured above; completeness separately (q23): 200 levels deep (deeper than the 48 folders held open), each level with 30 files sorting before the folder `m`, 30 files sorting after it, and the next level inside `m`; 12,000 files and 201 folders, built by the owner, then the real `install.sh` and `uninstall.sh`. After install all 12,000 files carried the agent's entry (the grant reached every file, so re-listing resumes correctly there too); after uninstall 0 of 12,000 files and 0 of the 402 folder lists carry one (counted by descriptor, nothing followed). No silent gap of the kind D was.

## Behaviour against `setfacl` and the walk rewrites
The randomised comparison from round 2 (`fuzz.py`, seeds 1 to 6: grants, second grants, parents, undo after random `chmod`, about 790 paths per seed) was re-run on b9e1b21: 0 mismatches in all six seeds. The widening check (`fuzz2.py`, 400 paths with random narrow masks, named user and group entries): 0 widened. That covers the walk rewrites and the `access_without_grant` change behaviourally; it does not exercise pre-existing masks on the undo path, which the recorded-mask probe below does.

## The accidental deletion of `undo_access` and `undo_default`
Compared every class and function of `lib/access_control_snapshot.py` between 2211d8f and b9e1b21 by parsed syntax tree hash (keyed by name, so the many nested `visit` and `__init__` definitions are merged and the counts are approximate): no definition removed; 42 of 60 names have identical syntax trees, including `undo_access` and `undo_default` (and `access_with_grant`, `default_with_grant`, `narrowed_to_mask`, `problems_in`, `command_quiesce`, `command_release`, the argument parser and its commands). Added: `Capped`, `Where` and small helpers. Changed: `Frame`, `walk`, `start`, `scan`, the commands that take the new `where` argument, `printable`, `finish_changes`/`report_errors`, `access_without_grant` (the recorded mask is now applied whenever the snapshot has one), `default_is_leftover`, `undo_leftovers`, `restore_folder`. I read the whole diff for those; each change is what the commit messages say, and the behaviour tests above all pass. The deletion is therefore harmless, and the fuzz runs above show the behaviour is intact.

## Should-fix items from round 3
- **Repair when the account is gone (item 5):** fixed. With the real a8c37e0 package (q16): install, old uninstall (12 leftover lines), then the helper's `repair` on the folder and the parent: lists identical to before the install ("EXACT ORIGINAL LISTS"). `sirven grant repair` with no grant record now tells you to name the folders with `--path FOLDER` (that form was read, not run).
- **Recorded mask:** fixed. A file with `user:bob:r--` and `mask::r--` comes back with its original mask after install and uninstall; the only remaining difference is the stored group entry (`group::rw-` shown as `r--`), which has the same effective access.
- Earlier spot checks (release check, locked-account message, whole-tree check, forking agent, upgrade path) are covered by the harness scenarios 16 to 21 that pass; I did not repeat them this round except where they overlap above.

## Must fix E (memory grows linearly with the number of folders)
`record` keeps one entry per folder (`scan` in `lib/access_control_snapshot.py`; about 0.8 KB each, in memory and in the snapshot) and `restore` loads it all. Measured (q22, q24): the agent made 300,000 empty folders in 8.2 s (about 37,000 a second, 300,000 present afterwards; the test machine had 3.8 million free inodes and real machines have far more), and then `record` (which runs again at the re-grant of a rollback to a lower level, after the agent is ended) peaked at 239 MB and wrote a 72 MB snapshot in 23 s; `restore` from it peaked at 335 MB; the install-time check stays at 38 MB. Extrapolated, not run: 3 million folders (about 80 s of agent work) would take about 2.4 GB in root's helper, which on a low-memory host ends in the out-of-memory killer. It fails closed (the step fails and the account stays locked; deleting the folders fixes it), but that was also true of C, which I made a must-fix because the agent could cause it cheaply. The only difference is a factor of about a hundred in the agent's effort, not a different kind of risk. Fix: record only folders that hold a list (and the start folder), write the snapshot as a stream, and read it back line by line; the "replaced during the grant" check can use the parent identity and name of listed folders only. A harness scenario: 300,000 empty folders made by the agent, then a rollback to a lower level, asserting peak memory under 100 MB.

## Should fix (for a later round)
1. A chain deeper than 30,000 levels still blocks a level change, a rollback or an uninstall until the owner removes it with `rm -r`. The message says so and the account is locked meanwhile, so I accept it; a bound of 30,000 is far beyond any real tree.

## Not tested
The `sirven grant repair --path` form, file systems other than overlay and ext4, xfs, btrfs, NFS, macOS (read only), and the real sshd lock-and-expiry (`command_quiesce` and `command_release` are unchanged apart from the kill loop verified in round 3).

## Result

CHANGES REQUIRED: fix E (small and local to `scan`, `record` and `restore`), add its scenario, then I would approve at once. Should fix 1 is optional. (The recovery text after a failed run is generic, "the same uninstall, rollback or repair command", which is right; I had first read it as uninstall-only because my output filter cut it.)

Reviewed head: b9e1b21. Commit adding this section: see `git log -1 -- docs/research/qa/sir-70-review.md` on branch `code-review-grant-access-model-and-snapshot-undo-thr_cvq2422xsz`.

---

# Re-review 5 (branch `sir-70-round-2-safe-undo-no-link-following-refus-thr_e75v2he8zw`, tip fa208c7)

Same method (fresh containers, scratch worktree of fa208c7). Probe scripts stay in `/tmp/sir70-probes`.

## Verdict: APPROVE (four small should-fix items; none can be triggered by the agent: a missing python module and a damaged or locked root-only file are conditions of the machine, the same line I have used since round 3)

Must-fix E is fixed. The new sqlite snapshot behaves well on every damaged file I tried that fails at the start; one damage pattern (corruption after a valid header) cannot be finished by the tool alone. A python3 without sqlite3 is a real configuration on Ubuntu, and the installer does not check for it up front.

## Gates, foreground, on fa208c7
- `bash tests/harness/run-linux.sh`: exit 0; 27 scenarios, 0 failed; the only known defects are the 4 in scenario 03 (SIR-32).
- `make test`: exit 2; 452 passed, 3 failed: the 3 known macOS installer tests.
- `make lint`: exit 0 (`bash -n` on 65 files; shellcheck not installed).

## Must fix E (memory linear in the number of folders): fixed
- The agent made 300,000 empty folders (q22, 2 GB container): install-time check 39 MB, `record` 39 MB (was 239 MB), `restore` 41 MB (was 335 MB). The 39 to 41 MB is mostly the one folder with 300,000 names being listed; the implementer's 15 MB figure is for a nested layout.
- The real flow (t5): builder then observer installed, the agent made 300,000 folders, then `bin/sirven grant rollback` (undo, quiesce, record, re-grant): exit 0, 24 s, peak 40 MB in the biggest process, 52 KB of snapshot left. (In q22 the snapshot is 49 MB only because that probe records while the grant's own lists are still on the folders; in a rollback the record runs after the undo, so it holds only what the tree had before.)
- Baseline, 301,001 entries: install 14.6 s in the first run and 10.9 s in a repeat (it was 11.4 s before, so the first figure was noise), uninstall 4.8 s then 4.1 s (4.3 s), 15 MB each (61 MB and 87 MB before), snapshot 52 KB (7 MB).
- Behaviour unchanged: the setfacl comparison (fuzz, seeds 1 to 3) 0 mismatches over about 790 paths per seed, widening check (400 paths) 0 widened, odd folder names with earlier default lists come back identical (q12), 12,000-level chain still cleaned at an open-file limit of 256 (q13).

## Is sqlite3 there?
Checked in containers (Docker engine on this Mac):

| Platform | `python3` from | `import sqlite3` |
|---|---|---|
| Debian 12 slim | `apt install python3` (3.11.2) | works (sqlite 3.40.1); `python3-minimal` also works there because apt pulled the standard library as a recommended package |
| Ubuntu 24.04 | `apt install python3` | works |
| Ubuntu 24.04 | `apt install --no-install-recommends python3-minimal` | **fails**: `ModuleNotFoundError: No module named 'sqlite3'` |
| Fedora (latest) | `dnf install python3` (3.14.8) | works (sqlite 3.51.2) |
| Alpine (latest) | `apk add python3` (3.14.8) | works (sqlite 3.53.4) |
| macOS 26 (this Mac, `/usr/bin/python3` 3.9.6) | system | works (sqlite 3.51.0); the Linux helper is not used on macOS anyway |

So the minimal Ubuntu python is the one gap (`apt install --no-install-recommends python3-minimal` gives a python3 without sqlite3; I did not check which cloud images carry it). Simulated by deleting `_sqlite3*.so` in a Debian container (t1, t2):
- Install: `install.sh` does not look for the module. It creates the account, ends and locks it, and fails at step 19 with `error: python3 has no sqlite3 module, so a snapshot cannot be written`, exit 4, nothing granted, account left `!*` expired, with the recovery text; uninstall then works (exit 0, account removed). Fail closed and loud, but only after the change started.
- Uninstall when the module disappeared after install (a snapshot exists, t2): `error: unexpected AttributeError: 'NoneType' object has no attribute 'Error'`, exit 4, agent entries left. Cause: `except (..., sqlite3.Error)` evaluates `sqlite3.Error` when `sqlite3` is `None`. Fail closed, an unhelpful message.

## Damaged or locked snapshot (t3, t4)
Each case: install with an owner-made default list on one folder (so the snapshot holds a row), damage the snapshot, run uninstall.
- Truncated to half, random bytes, empty file, a valid sqlite file with the wrong tables, and a file held under an exclusive lock by another process: uninstall exits 0 after a loud `warning: ... the snapshot ... cannot be used (...)`, the grant's entries are all removed (0 left), and the owner's own earlier default list on that folder is lost. That loss is wider than before the grant: with the owner's `default:other::---` gone, a file the owner makes there under umask 022 comes out mode 644 (shown in t6), where it was private. The round 2 design accepted this with a loud warning, so it does not block, but it is a widening and the warning is the only protection. The locked case waited 5 seconds, and then (t6) the intact snapshot was deleted: after the fallback warning `restore` returns 0 and `command_restore` removes the file, so a busy lock on a good snapshot costs the owner's earlier lists and the snapshot itself. Intact snapshot (control): exit 0, lists identical to before, owner's default list kept.
- Corrupt in the middle only (header and `meta` table fine, entries pages overwritten; t4, 6,000 rows): uninstall exits 4 with `error: unexpected DatabaseError: database disk image is malformed`, 3,979 agent entries left, account locked; a rerun fails the same way, and nothing tells the owner to remove the snapshot file. Only a root-owned file, so not agent-triggerable, but it is a dead end for the tool.

## The link-swap warning
Acceptable. Never following a link is unchanged: scenario 07 now swaps a folder that held a list (`sub`, still named in the audit log) and a plain folder (`plain`), and asserts both link targets are exactly as they were. What is lost is only the audit signal for a swapped plain folder. That signal is weak anyway: the agent may make links in its own tree, and a renamed plain folder (same inode) is still walked and undone. If an audit trail for links matters, count links met in the tree and report the number, without naming them.

## Should fix
1. Preflight: for Linux, check `python3 -c 'import sqlite3'` in `preflight_python` (and in the dry run), with the message "install the python3 standard library package (on Ubuntu: apt install python3)". Today it fails after the account was locked.
2. Guard `sqlite3 is None` in the `except` clauses (`load_snapshot`, `start_checked`): build the tuple of errors once, with `sqlite3.Error` only when the module exists, and say "python3 has no sqlite3 module, so the snapshot cannot be read" in the warning.
3. Catch `sqlite3.DatabaseError` inside the walk (or run `PRAGMA quick_check` at open): treat a snapshot that goes bad mid-walk like a missing one (warn once, continue removing the grant's entries, exit 0), or at least tell the owner to remove the snapshot file and rerun.
4. A locked snapshot (`database is locked`) should be retried or fail the step (exit 1, file kept), not fall back; and any snapshot judged unusable should be renamed aside (for example `.unusable`), not deleted, so the owner can recover the earlier lists.

## Not tested
`record` with hundreds of thousands of rows in the snapshot beyond the 300,000-row run (q22: 49 MB, restore 10.8 s), file systems other than overlay and ext4, macOS (the helper is Linux only), the real sshd lock (unchanged).

## Result

APPROVE. Fix should-fix 1 to 4 in a follow-up.

Reviewed head: fa208c7. Commit adding this section: see `git log -1 -- docs/research/qa/sir-70-review.md` on branch `code-review-grant-access-model-and-snapshot-undo-thr_cvq2422xsz`.
