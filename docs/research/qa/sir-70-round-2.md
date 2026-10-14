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

At this branch: `bash tests/harness/run-linux.sh` exit 0, 14 scenarios, 0 failed, 4 known defects (all SIR-32, the kill
switch, unchanged).

## Not verified

- Anything on macOS: the `-h` change, `find -P`, and the manual check in `docs/PERMISSIONS.md`.
- A filesystem without access list support, and Linux filesystems other than the container's overlay.
- Rollback's removal half runs with the agent's account still running and relies on the descriptor method alone
  (probes with the agent swapping a folder in a loop left the target untouched; a probe is not proof). The re-grant
  half, a level-change re-install, and a first install now use the same descriptor based helper and end and lock the
  agent first, so no path is followed in the grant direction either. What is still by path is read only (probes that
  decide a step is already done).
- That `usermod --expiredate 1 --lock` stops SSH key logins: the harness runs no SSH server.
