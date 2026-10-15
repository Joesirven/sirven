# Full real-install harness on Ubuntu 24.04 and Fedora 42, 2026-10-15

Checked against origin/main at f600591, on the branch harness-full-ubuntu-fedora. Tracked on the bb task SIR-9. Each run is the whole scenario list (68 scenarios) with `SIRVEN_HARNESS_IMAGE=<image> bash tests/harness/run-linux.sh`, one image at a time. Before this check only the core subset (01, 02, 30, 31, 32) had run on these two images.

## Result

| Image | First full run | After the test fixes below |
|---|---|---|
| Ubuntu 24.04 | exit 0, 68 scenarios, 0 failed | unchanged (the changed scenarios were rerun, exit 0) |
| Fedora 42 | exit 1, 68 scenarios, 5 failed (21, 30, 40, 42, 52) | 2 failed (40, 52), both a product defect (finding 1) |

## Classification of the five Fedora failures

| Scenario | Failing line | Class | Cause |
|---|---|---|---|
| 21-upgrade-over-an-old-install | "the older version installs: wanted exit 0, got 2", and three assertions that depend on it | test portability, fixed; the underlying behaviour is finding 1 | The scenario copied the older package to `/tmp/older`, and Fedora refuses to run from `/tmp` (finding 1). The folder is incidental to what the scenario asserts, so the copy now goes to `/work/older`, a folder only root can write. Scenario 52 still asserts the `/tmp` case. |
| 30-revoke-live-session-and-key-login | "precondition: the default sshd configuration reads authorized_keys2 too" | test portability, fixed | Fedora's OpenSSH ships `AuthorizedKeysFile .ssh/authorized_keys` only (`/etc/ssh/sshd_config` line 49 in the image); Debian 12 and Ubuntu 24.04 also read `authorized_keys2`. The scenario now starts sshd with `-o "AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2"` and checks that same option in the precondition. The assertions about revoke (both key files gone, login refused) are unchanged. The kill switch removes both names on every distribution (`lib/kill_switch.py:28`). |
| 42-revoke-refuses-system-accounts | "www-data (user number ): refused" and "www-data: the message says it is a system account" | test portability, fixed | The scenario used `www-data`, a Debian account; Fedora has no such account (its web servers use `apache` and `nginx`, also absent from the image). Replaced by `mail`, a system account that exists on all three images. The assertion (a system account below the ordinary range is refused, untouched) is unchanged. |
| 52-gate-trust-claims | "package inside a sticky world-writable folder like /tmp: refused but should be accepted" | real product defect | Finding 1. |
| 40-revoke-from-a-folder-the-agent-can-write | "(2) it names the file and the entry" | real product defect | Finding 1 and finding 2. |

## Finding 1: a sticky world-writable folder such as /tmp is refused as a place to run from on Fedora

- **Scenarios:** 52 (line 22, "package inside a sticky world-writable folder like /tmp"), and through the same check 21 before its fix.
- **Failing output:** `error: refusing to run as root from /work/tmp6/pkg: ... /work/tmp6: writable by the group root (mode 1777), which has other members`.
- **Cause:** `install.sh:88` exempts a sticky folder on the path from the "writable by everyone" rule (`mode & 0o002 and not (on_the_way and mode & stat.S_ISVTX)`), but `install.sh:90-91` has no such exemption for the group-write bit that mode 1777 also carries. That bit passes only if `group_trusted(gid)` (`install.sh:69-74`) says every member of the folder's group is root or the owner. `group_trusted` counts every account whose primary group number is the folder's, not only names listed in the group file. On Debian and Ubuntu only root has primary group 0, so group root is trusted and the sticky folder passes. On Fedora 42 the accounts `sync`, `shutdown`, `halt` and `operator` also have primary group 0 (read from `pwd.getpwall()` in the image; the group file lists no members), so group root is not trusted and every sticky folder owned by root:root is refused.
- **Same code in three files:** `install.sh:69` and `:88-91`, `uninstall.sh:75` and `:94-97`, `bin/sirven:82` and `:101-104`.
- **Impact:** on Fedora (and, not tested here, other distributions that give those four accounts group 0, such as Red Hat Enterprise Linux), installing, repairing or uninstalling from a copy under `/tmp` or `/var/tmp` fails with exit 2 and "nothing was changed". The refusal is safe, not a loosening, and the message names a way out (run from a root-only folder), but the message blames "other members" of group root, who are nologin system accounts and cannot use the folder in any way a sticky folder does not already prevent. A first-time Fedora user who downloads to `/tmp` hits it immediately. Scenario 52's sticky-folder assertion states the intended behaviour and fails on Fedora until this is decided.
- **Not fixed here:** product code. The parent files the ticket.

## Finding 2: an access list mask is reported as "writable by the group root"

- **Scenario:** 40, line 42, "(2) it names the file and the entry".
- **Failing output:** the install is refused (exit 2, as the previous assertion expects) but names `/work/bad/lib/audit.sh: writable by the group root (mode 664), which has other members` instead of `audit.sh: an access list entry gives intruder write`.
- **Cause:** after `setfacl -m u:intruder:rw`, the file's group permission bits as read by `os.lstat` are the access list mask (rw), not the owning group's own permission (`install.sh:90` uses `mode & 0o020`). On Debian and Ubuntu this goes unnoticed because `group_trusted(0)` is true (finding 1), so the code falls through to the access list check (`install.sh:92-100`) and prints the precise reason. On Fedora the group test fires first with a wrong reason: the group root cannot write the file, the entry for `intruder` can. Same lines in `uninstall.sh:93-97` and `bin/sirven:100-104`.
- **Impact:** the refusal is still correct; only the explanation names the wrong cause, and a reader would look at group root instead of the access list entry for the other account. The defect exists on every distribution and is hidden by finding 1's absence on Debian. It would also matter on Debian for a file owned by a group with other members and an access list.
- **Not fixed here:** product code.

## Environment (not a product defect, not a test change)

- Scenario 62-tailscale-live-join-and-logout: "apply joins the test tailnet as tag:agent" and "status reports connected, a second apply does nothing, revoke logs the node out" are skipped on every image because no `SIRVEN_TAILSCALE_AUTHKEY` was supplied. Those scenarios always use the Debian Tailscale image.
- Scenarios 67 and 68 (the AppArmor ones): "under AppArmor the chain stops at Errno 36" is skipped because Docker Desktop on this Mac has no AppArmor ("no AppArmor in this container (profile: none)"). This is the same on all three images.
- On Ubuntu 24.04 two assertions are skipped with "this image's account tool makes no mail spool" (the service user's mail spool after install and uninstall). On Fedora those two assertions did not skip (no skip line in the log).

## Commands

All from the worktree of the branch, log files private under a temporary folder. Exit status in brackets.

1. `SIRVEN_HARNESS_IMAGE=ubuntu2404 bash tests/harness/run-linux.sh` [0]: "68 scenarios, 0 failed".
2. `SIRVEN_HARNESS_IMAGE=fedora bash tests/harness/run-linux.sh` [1]: "68 scenarios, 5 failed" (21, 30, 40, 42, 52).
3. `SIRVEN_HARNESS_IMAGE=fedora bash tests/harness/run-linux.sh 40-revoke` [1]: reproduces scenario 40 alone, 23 passed, 1 failed. Scenario 40's output was read by temporarily printing the captured refusal (not kept).
4. After the test fixes, `SIRVEN_HARNESS_IMAGE=<fedora|ubuntu2404|debian12> bash tests/harness/run-linux.sh 21-upgrade,30-revoke-live,42-revoke` [0, 0, 0]: each "3 scenarios, 0 failed".
5. `make lint` [0]; `make test` [0], 574 passed, 0 failed (a first run failed `test_no_whole_array_expansion` on an array in scenario 30; rewritten as a plain string).
6. The command in item 4 again on the final scenarios [0, 0, 0]: each "3 scenarios, 0 failed".
7. `bash tests/harness/run-linux.sh` (default image, Debian 12) [0]: "68 scenarios, 0 failed".
