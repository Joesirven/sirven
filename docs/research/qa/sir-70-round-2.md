# SIR-70 round 2: undo that removes only what the grant added

Branch `sir-70-round-2-safe-undo-no-link-following-refus-thr_e75v2he8zw`, starting from 66e31fe. The first round's
review (`docs/research/qa/sir-70-review.md` on branch `code-review-grant-access-model-and-snapshot-undo-thr_cvq2422xsz`,
commit a8bc94a) returned CHANGES REQUIRED with six must-fix items. This note records how each was fixed and the
evidence that each new harness assertion fails at 66e31fe.

## What changed

| Must fix | Change |
| --- | --- |
| 1 undo changed owner, mode, special bits | `lib/access_control_snapshot.py` removes only the agent's and the folder owner's named entries and the default list that carries the agent's entry. It never calls chown or chmod, and with no named entry left it collapses the list to a plain mode (group bits = group entry AND mask), so an owner's later `chmod 600` stays. The reviewer's text-restore fixes (a line-anchored test, stripping the owner, group and flags comment lines) are superseded: there is no text restore at all. One deliberate exception to "never change a mode": a chmod that widens the group bits during the grant (644 to 664) changes only the mask, and undo ends at 644, the access the group really had; using the mask as the group bits would widen a file nobody granted. Scenario 06 asserts it. |
| 2 link attack | Nothing is done by path. The start folder is opened one component at a time with `O_NOFOLLOW`, must be the recorded device and inode, and the walk uses descriptors. A folder replaced by a link is skipped with a `warning` event in the audit log. Undo ends the agent's processes and expires its account before the first list is put back. |
| 3 pre-existing named entries | Refused before any change (`check`), access and default lists, granted paths and pass-through parents, up to ten paths listed. The agent's and the folder owner's own entries (an earlier grant) do not count. |
| 4 newline and backslash names | Names are handled as bytes end to end, no text round trip. |
| 5 missing snapshot | The undo check is the state of the folder, not the snapshot file. With no snapshot undo still removes the grant's entries, warns loudly and writes an audit warning, and exits 0 (non-zero would stop uninstall before the account is removed). `repair` covers installs made before snapshots. |
| 6 owner with no account name | The agent and the owner are written by number, looked up when the step runs. |
| grant direction (parent decision after the review) | The grant itself moved into the helper (`grant-access`, `grant-default`), by descriptor, no link followed. `quiesce` and `release` end the agent's processes and lock and expire its account around any grant step that has work to do, then give the account back as it was. Scenario 15. |
| macOS (from the reviewer's final report) | `chmod -h +a` and `-h -a`, and `find -P`. Plan only, not run on a Mac. |

## Evidence: new assertions at 66e31fe and at this branch

Scenarios 06 to 14 were run against a worktree of 66e31fe (with only the new scenarios and harness reader copied in)
and then against this branch. Container: Docker on the Mac, no network.

| Scenario | Fails at 66e31fe | Also passes at 66e31fe (precondition or guard) |
| --- | --- | --- |
| 06 owner changes survive undo | chmod 600 stayed; another account cannot read it; setgid and sticky stayed; setuid stayed; root's chown and chmod stayed; root's chmod 700 on the parent stayed | install and uninstall exit 0; untouched paths unchanged; pipe and socket guard; the chmod 664 exception ends 644; no list left |
| 07 link swap | link target unchanged (owner, mode, lists); still root 700; audit warning; agent ended before the first list is put back | install, the swap, uninstall exit 0; moved folder cleaned; no agent process left |
| 08 existing lists refused | refusal exit 2 (three cases); messages name the path and why; nothing changed; no account created; bob unchanged; ten listed and the rest counted | preconditions; install applies after the lists are removed |
| 09 odd names | lists, owners and modes back exactly; oddly named folders kept their default lists | install, agent access and uninstall exit 0 |
| 10 snapshot deleted | warning text; audit warning; restore step not reported done; machine back as it was | install and uninstall exit 0 |
| 11 numeric owner | install exit 0 (was 4 at step 22); owner entry by number | agent can write; uninstall exact (nothing half-applied was left to undo) |
| 12 rollback | chmod 600 and chmod 700 kept after rollback and after uninstall; other account still blocked | the three installs and rollback exit 0; earlier level back; no list left |
| 13 nested and repeated grants | none (a regression guard, passes at both) | all |
| 15 re-grant while the agent runs | link target unchanged after a rollback with a swapping agent; agent ended during the re-grant; audit warning | installs and rollback exit 0; precondition; account back; observer level back |
| 14 repair command | repair exits 0 (was 2: no such command); no entry left; exact | owner's chmod; uninstall exit 0 |

Counted: 45 of the assertions in scenarios 06 to 15 fail at 66e31fe. The others are preconditions (for example "a process of agent is
running"), the install and uninstall exit statuses that must still be 0, and regression guards (all of scenario 13, the pipe and
socket check, the chmod 664 exception), so it is not true that every new assertion fails at the first round's tip; the table says
which do. Scenario 01 also changed its step counts (23 steps, 22 skipped on a re-run) for the two new account steps.

At this branch: `bash tests/harness/run-linux.sh` exit 0, 15 scenarios, 146 assertions passed, 0 failed, 4 known defects (all
SIR-32, the kill switch, unchanged). `make test` exit 2 with the 3 known macOS installer failures only (446 passed). `make lint`
exit 0 (the shell linter is not installed, so only syntax was checked).

## Not verified

- Anything on macOS: the `-h` change, `find -P`, and the manual check in `docs/PERMISSIONS.md`.
- A filesystem without access list support, and Linux filesystems other than the container's overlay.
- Rollback's removal half runs with the agent's account still running and relies on the descriptor method alone
  (probes with the agent swapping a folder in a loop left the target untouched; a probe is not proof). The re-grant
  half, a level-change re-install, and a first install now use the same descriptor based helper and end and lock the
  agent first, so no path is followed in the grant direction either. What is still by path is read only (probes that
  decide a step is already done).
- That `usermod --expiredate 1 --lock` stops SSH key logins: the harness runs no SSH server.

# Round 3 (re-review of 1ce7450)

The re-review (`git show 6dfea02:docs/research/qa/sir-70-review.md`, "Re-review" section) found two must-fix items and six
should-fix items. All are done on this branch; scenarios 16 to 21 are new.

| Item | Change | Scenario |
| --- | --- | --- |
| A the agent can block a step down or a rollback | The refusal is exact: another account's (or a named group's) entry with bits outside the current mask, on a path the agent does not own. The agent's and the owner's entries and the group entry are not counted; the grant narrows the group entry and the other named entries to the old mask before it raises the mask, so a re-grant never switches on what an owner's chmod or a narrow mask switched off. No exemption for rollback. The message names `setfacl -x`. | 16 |
| B a deep tree breaks undo | The walk is iterative, keeps the deepest 48 folders open, reopens through `..` with a device and inode check, raises the soft descriptor limit, caps at 30,000 levels (reported by name), turns every exception into `error:` and a `recovery:` line. The snapshot records name and parent, not whole paths. | 17 |
| 1 re-run after a crash leaves the account expired | the release step is not done while its marker exists | 18 |
| 2 a failed run does not say the account is locked | install, rollback and uninstall print that, and how to give the account back | unit tests (a failure mid-grant cannot be made inside the harness container: no way to mount a read-only folder) |
| 3 one kill pass | `quiesce` repeats until the agent has no process, at most 20 times | 19 |
| 4 a partial recursive grant judged done | the grant checks read the whole tree (`verify-access`, `verify-default`); the mask is not compared | 18 |
| 5 repair needs the account | `repair` with the account gone removes what an old undo left, lists it first, `--dry-run` lists only | 20 |
| 6 in-place upgrade refused | the refusal names `sirven grant repair`, then the old `uninstall.sh`, then install; `sirven grant repair` is new and the whole path is a scenario | 21 |

One deliberate difference from the re-review's wording of A: the group entry is not refused. A mask narrower than the group entry
is the state an owner's `chmod 600` leaves, and refusing it would block every rollback after such a chmod (a round 1 behaviour the
re-review accepted). The grant clears the group bits the mask switched off instead, so the group stays shut out. Foreign named
entries are still refused when they exceed the mask, as the re-review asked.

Against 1ce7450: scenario 16 fails 8 assertions, 17 fails 3, 18 fails 6, 19 fails 1 (it is probabilistic: a forking loop
survives one kill pass in some runs only), 20 fails 6, 21 fails 3. A randomised comparison of `grant-access` and `grant-default` with
`setfacl` on 48 random trees (modes, special bits, pipes, five permission sets) matched exactly. Not done from the nice-to-have list:
the openssh-server image change (so the lock-and-expire claim stays unproven in this harness), the hard-link sysctl warning, and
the narrower default-list removal.

# Round 4 (re-review 3 of 2211d8f)

| Item | Change | Scenario |
| --- | --- | --- |
| C memory grows with depth times name length | A folder in the walk is a few small values and its own name; the path is built only when printed (`Where`); the listing is kept only while the folder is held open and is read again, sorted, after the last name read, when it is reopened; problems are counted and only the first ten kept; the install-time check no longer builds snapshot records. | 22: 3,000 levels of 255-character names and 240,000 long-named files, peak 24 MB in the check and 18 MB in uninstall (limit 60 MB). At 2211d8f the check was killed (214 MB, exit -9 in a 256 MB container) and uninstall was killed. |
| 301,001-entry baseline | install 11.5 s and 61 MB, uninstall 4.4 s and 88 MB (re-review: 11.6 s and 60 MB, 4.2 s and 87 MB). Unchanged. | probe, not a scenario |
| D a lost subtree skipped silently | every dropped frame is an error naming the folder ("moved, replaced or removed while it was being read ... run the same command again") plus the recovery line; a rollback now starts with the step that ends the agent's processes and locks its account and ends by giving it back, also when it rolls back to no grant. | 23 (exact-timing hook: a folder moved away from under a 60-level walk; fails loudly, the second run after the tree is put back clears all 20 files), 24 |
| the 31,000-level case | reported by name with the bound and a recovery hint, the rest of the undo continues, a second uninstall after `rm -r` finishes; long paths are shortened to their two ends when printed | 26 |
| should fix 1: repair with the account gone leaves the default list | a default list with a mask and no live named entry is an older leftover (the older grant copied the folder's group and other bits into it); `sirven grant repair --path` works without a grant record | 25 |
| should fix 2: the mask comes back wider | the recorded mask is restored when the grant's entries come off a path that had named entries | 25 |

Against 2211d8f: scenario 22 fails 6 assertions, 23 fails 3, 24 fails 5, 25 fails 6, 26 fails 3.
