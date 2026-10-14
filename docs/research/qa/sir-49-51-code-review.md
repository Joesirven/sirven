# Code review: SIR-49, SIR-50, SIR-51

Reviewed: `git diff origin/main...HEAD` on branch `code-review-pinned-bootstrap-local-copy-python3-thr_s3x48myuig`,
commits 4125b15 (pinned bootstrap), 612e17a (python3 placeholder guidance), 8e75f72 (kept copy of the
package), 3381525 (documentation). Reviewed inline by one reviewer, then a separate verification pass
that re-ran each claim and re-checked every cited line number with `grep -n`. Each finding says how it was
established: "reproduced" means a command was run and its output observed; "read" means code reading only.
No workflow run was used (the capacity tool gave no reading for this machine), and nothing was run as
root or against the real installer on this Mac.

Bash used for all runs: `/bin/bash` 3.2.57 (macOS default).

## Verdict: CHANGES REQUIRED

The bootstrap's core guarantee holds: nothing is unpacked or run until the checksum matches, and a
missing pin, malformed pin, failed download and mismatch all stop with nothing executed. Three defects
must be fixed first: two in the kept copy (SIR-51) and one in the final line of the bootstrap.

## Command results

| Command | Result |
| --- | --- |
| `make test` | exit 2, 393 passed, 3 failed: exactly the three known failures (`test_install_started_by_sh_says_to_use_bash`, `test_enter_twice_accepts_the_shown_defaults`, `test_input_that_ends_takes_the_defaults`). Run outside the sandbox. |
| `make lint` | exit 0, but only `bash -n` ran on 57 files. `shellcheck` is not installed on this Mac, so the static analysis step was skipped. Nothing in this review was linted by shellcheck. |
| Bootstrap, pinned fixture, `/bin/bash -s -- --dry-run < file` and `cat file \| bash -s -- --dry-run` | exit 0, installer ran once with the arguments, standard input not a terminal, no temp directory left behind. |
| Bootstrap, mismatched pin | exit 1, "Nothing was unpacked or run", temp directory removed. |
| Bootstrap, pin `a` followed by 63 `z` | accepted by the shape check, stopped at the mismatch check (fails closed). |
| Bootstrap, SIGTERM and SIGHUP to the bootstrap while the installer runs | temp directory removed (but see the row below about the installer child). SIGINT could not be tested honestly from a background job (a non-interactive shell ignores it there), so Ctrl-C cleanup is unverified. |
| Truncation sweep, every prefix length of the pinned bootstrap piped to `bash -s -- --dry-run` | 5 of 4360 prefixes ran the installer, 3 of them without the user's arguments; see must fix 3. |
| Same sweep on a scratch copy with the argument guard from must fix 3 added | 2 of 4593 prefixes ran the installer: the complete script, with and without its final newline, both passing `--dry-run`. The guard works. |
| Bootstrap, SIGTERM and SIGHUP sent to the bootstrap process alone | the installer child kept running after the temp directory it runs from was deleted; see should fix 5. |
| Scratch-copy mutation: move the checksum comparison after `tar -x` | `tests/unit/test_bootstrap.sh`: 8 passed, 0 failed. The tests do not notice; see should fix 3. |
| Scratch-copy mutation: remove `--proto '=https' --tlsv1.2` from `curl` | 8 passed, 0 failed. Not noticed. |
| Scratch-copy mutation: disable the checksum comparison | 1 failed (`test_mismatched_checksum_runs_nothing`). That check is covered. |
| `install.sh --dry-run` as macOS with a fake `xcode-select` (exit 2) and a fake placeholder `python3` | stopped with the xcode-select message; the fake `python3` was never run (marker file absent). |
| `codeload.github.com/.../refs/heads/main` downloaded twice, and the `github.com/.../archive/...` form once | identical bytes (same checksum) in all three. |

## Must fix

### Must fix 1. A failed or partial copy is marked complete, and the installer can delete itself

`lib/layout.sh:81-93` (`layout_keep_package`), run from `lib/plan.sh:407`.

`plan_apply` runs each action as `if ! ( eval "$action" )`. Inside that construct `set -e` is off, so a
failing `cp -R` in the loop at `lib/layout.sh:89-91` is ignored, and the last command, the marker write
at line 92, succeeds. The step then reports "done" and records its undo. The skip check
(`[ -f $copy/PINNED-COPY ]`, `lib/layout.sh:124`) trusts the marker, so every later run skips the broken
copy.

Reproduced: with `components/` missing from the source, `layout_keep_package` printed
`cp: ... components: No such file or directory`, returned success, and left a directory holding
`PINNED-COPY` without `components`. A full disk does the same (read, not reproduced). A killed process
cannot cause it, because it never reaches the marker write.

Second symptom of the same code: `rm -rf "$destination"` at line 87 runs before the copy. Running the kept
copy's own `install.sh` when its marker is missing (marker deleted by hand, or removed by a damaged copy)
makes the source and the destination the same folder. Reproduced: the run printed "applied 1 steps" and
the copy was left holding only `PINNED-COPY`, with every other file deleted.

Fix, in `layout_keep_package`:

1. Refuse when `$(cd "$source" && pwd -P)` equals the destination's resolved path, or lies inside it.
2. Copy into `"$destination.new"` (after `rm -rf` of that name only), and give every command an explicit
   `|| return 1`, since errexit cannot be relied on: `cp -R "$source/$item" "$staging/" || return 1`.
3. Before the marker, check every name in `LAYOUT_PACKAGE_FILES` exists in the staging folder
   (`[ -e "$staging/$item" ] || return 1`).
4. Write the marker last into staging, then `rm -rf "$destination" && mv "$staging" "$destination"`.
5. Make the skip check at line 124 prove completeness too (see must fix 2), not only that the marker
   exists. This is also where a run from the copy itself must be recognized: see the next section.
6. Add tests: a source missing one item must make the step fail and leave no `package` folder; running
   the installer from the copy must not shrink it.

### Must fix 2. A re-run or upgrade keeps the old copy for ever; judged as must fix before release

`lib/layout.sh:124` (the check `[ -f $copy/PINNED-COPY ]`) and `docs/BOOTSTRAP.md:80-81`.

Reproduced: install, then re-run with `SIRVEN_PACKAGE_TAG=v0.3.0 SIRVEN_PACKAGE_SHA256=newsum`. Output:
"keep a pinned copy ... (already done)", "applied 0 steps", and the marker still read `tag=unpinned`.

Why this is harmful and not only untidy: the copy is the code that runs revoke and uninstall, and the
uninstaller replays action text stored in the install record (`/var/lib/sirven/install-record.tsv`; the
record line for this step contains the literal `layout_remove_package_copy ...`). A later release that
records a new undo helper leaves a record the old copy's `lib/layout.sh` cannot execute, so the copy that
exists to undo the install fails to undo it. The copy also stays frozen on the security-relevant code
(revoke) of the oldest release ever installed. The existing test `test_rerun_keeps_the_copy_it_has`
(`tests/unit/test_install.sh`) asserts this behavior as intended; it must change.

Fix: make the check compare identity, and handle the run-from-the-copy case explicitly. `plan_layout` is
reached by every `install` run (`install.sh:214`, inside `build_install_plan`; `revoke` takes
`plan_kill_switch` instead, so revoke is not affected). So the documented path `sudo bash
/var/lib/sirven/package/install.sh` builds this step with `ROOT_DIR` equal to the copy. Run from there,
`SIRVEN_PACKAGE_TAG` is unset, so a naive "marker must equal the current tag" check would read `unpinned`,
see a mismatch with the stored tag, and try to refresh the copy from itself (a self-delete, or after the
guard in must fix 1, a hard failure). Required behavior: when `ROOT_DIR` resolves to the copy, the step is
done (check succeeds); and `install.sh` run from a copy should take its tag and checksum from its own
marker when `SIRVEN_PACKAGE_TAG` is unset, so that nothing downstream relabels it `unpinned`.

The check, otherwise:  Replace the check with a command that succeeds only when the marker
holds the current tag and checksum and is not `unpinned`, for example
`grep -qx "tag=${SIRVEN_PACKAGE_TAG:-unpinned}" marker && grep -qx "sha256=${SIRVEN_PACKAGE_SHA256:-unpinned}" marker`.
For the `unpinned` (checkout) case, either always refresh, or compare the files with `diff -r`. A refresh
goes through the staging-and-move path from must fix 1, so a failed refresh keeps the old working copy. Update the
sentence in `docs/BOOTSTRAP.md` and the comment at `lib/layout.sh:126`, and replace the test with
"a re-run from a different release replaces the copy", "a re-run from the same release leaves it".

### Must fix 3. A pipe cut inside the last line runs the installer without the user's arguments

`bootstrap/sirven-bootstrap.sh:100` (`main ${1+"$@"}`).

The file-level design (everything inside `main`, called last) correctly stops a cut anywhere before the
last line: a cut inside the function body is a syntax error. Reproduced with a sweep of every prefix
length piped to `/bin/bash -s -- --dry-run`: prefixes 4349 and 4350 of 4360 (`main` or `main `) ran the
verified installer with `args=[]`, 4351 ran it with the literal argument `$`, and only 4359 and 4360
passed `--dry-run`. So a truncated download of `curl ... | bash -s -- --dry-run`, the documented safe
preview (`bootstrap/sirven-bootstrap.sh:11`, `docs/BOOTSTRAP.md:76`), can run the installer as a real
install. The checksum still holds, so the installed code is the pinned release, but the user's
instruction is dropped. The live bootstrap has the same last line, so this is inherited, not new, but
this task asked for exactly this path.

Fix (three lines): near the top, `SIRVEN_BOOTSTRAP_ARGUMENTS="$*"` and `SIRVEN_BOOTSTRAP_ARGUMENT_COUNT=$#`
(both safe under `set -u`), and the first statement in `main`:
`[ "$#" -eq "$SIRVEN_BOOTSTRAP_ARGUMENT_COUNT" ] && [ "$*" = "$SIRVEN_BOOTSTRAP_ARGUMENTS" ] || fail "this script was cut off before its last line; nothing was run"`.
With no arguments a cut at `main` is identical to the full line, so it is harmless. Add a test that pipes
a bootstrap truncated at `main ` into `bash -s -- --dry-run` and expects exit 1 and no installer output.

## Should fix

### Should fix 1. The documentation promises a revoke that the installer refuses to apply

`docs/BOOTSTRAP.md:73-77`, `lib/layout.sh:129` (the note "later, without this repository: sudo bash ...
revoke --all"), `docs/WALKTHROUGH.md:73`.

Reproduced: `bash <copy>/install.sh revoke --all --prefix <fake root>` exits 3 ("the kill switch is plan
output in the alpha cut; apply comes in alpha + 1"). Only the dry run works, and uninstall from the copy
does work (exit 0, the copy removes itself). Fix: say in `docs/BOOTSTRAP.md` that revoke prints its plan
in the alpha and uninstall is applied, and keep the `layout.sh:129` note worded as future ("later", as it
is) but not as a working path.

### Should fix 2. The pin depends on GitHub keeping its archive bytes stable, and `release.sh --tarball` can pin bytes GitHub never serves

`bootstrap/release.sh:79-86` and `:44-48`, `bootstrap/sirven-bootstrap.sh:77`.

The URL form is the same in both scripts (`codeload.github.com/$REPOSITORY/tar.gz/refs/tags/$TAG`), and
today three downloads of the main archive, two URL forms, gave identical bytes, so the pin matches what
the bootstrap downloads. But GitHub does not promise stable archive bytes (it changed its archive
compression in January 2023 and reverted; treat that as a recollection to check, not something verified
here). If the bytes ever change, every installer fails closed at once with "tell the maintainer": safe,
but a global outage with no repair short of a new pin and a new deploy.

Separately, `--tarball FILE` pins the checksum of any file: a `git archive` made locally has different
bytes from what codeload serves, and `release.sh` writes that pin without a word. Every install then fails.

Fix: (a) prefer a release asset the maintainer uploads (`gh release create` with the exact tarball), whose
bytes GitHub does not regenerate, and download that in the bootstrap; or at least (b) make `release.sh`
always download the tag itself, and make `--tarball` require that the downloaded bytes match the given
file (or limit `--tarball` to tests behind an environment variable). Also have `release.sh` download
twice and compare, so a non-reproducible archive is caught at release time. Keep the repository name and
URL form in one place: they are written out in two files (`release.sh:23,81`, bootstrap line 19, 77) and
only convention keeps them equal; add a test that extracts both and compares.

### Should fix 3. Test gaps: several checks could be removed without a failing test

`tests/unit/test_bootstrap.sh`, `tests/unit/test_install.sh`.

- No test runs the bootstrap the way users do (`bash -s -- ARGS < file`); every test uses `bash FILE`.
  So the truncation defect (must fix 3), the standard-input handling and the `</dev/null` behavior are untested.
- Mismatch test (`test_mismatched_checksum_runs_nothing`) proves the installer did not run, but it still
  passes when the checksum is compared after `tar -x` (mutation run: 8 passed). The claim "checked before
  anything is unpacked" has no test. Give the fixture a tarball that `tar` cannot read: with the check before the
  unpack the error is the mismatch, otherwise it is a tar error.
- The fake curl ignores its flags, so removing `--proto '=https' --tlsv1.2` (`sirven-bootstrap.sh:51`)
  breaks nothing (mutation run: 8 passed). Log the arguments and assert them.
- There is no round trip: `release.sh` pins a fixture, then that pinned file runs against the same
  bytes. That test is the one that catches "release.sh computes a different checksum than the bootstrap".
- No test for a temp directory left behind after success, mismatch or failed download.
- SIR-51: no test for a partial copy, copy-from-copy (must fix 1), refresh on a new release (must fix 2, and the current
  test asserts the opposite), or the mode of the copy.
- Positive: the SIR-50 tests are sound. The placeholder test fails if the check is removed, because the
  fake `python3` leaves a marker file; the Homebrew and developer-tools-present cases are covered.

### Should fix 4. Documentation accuracy for Macs

`docs/WALKTHROUGH.md:36`. The sentence "the installer stops and asks you to run `xcode-select --install`"
is true only with `--dry-run` or `--prefix`: on a real Mac without `--dry-run`, `install.sh` stops earlier
with "applying to a real macos machine is not verified yet" (`lib/plan.sh:322`, called at `install.sh:300`,
before preflight at line 303). Since a Mac cannot apply at all yet, the kept copy of the package (SIR-51) is
never created on a Mac either; say so in `docs/BOOTSTRAP.md` so nobody expects it.

### Should fix 5. A direct kill of the bootstrap leaves the installer running without its files

`bootstrap/sirven-bootstrap.sh:75` (`trap cleanup EXIT`) and line 97 (the `bash "$installer"` call).

Reproduced: after SIGTERM or SIGHUP sent to the bootstrap process alone, the temp directory was removed
(good) but the installer it had started kept running (`pgrep` still showed its `sleep`), now executing
out of a deleted folder. A real installer calls `python3 "$ROOT_DIR/lib/..."` later in its apply, so it
would fail partway through, possibly after changing the machine. A Ctrl-C or a closed terminal signals
the whole process group, so the child dies too; this matters for a direct `kill` of the bootstrap only,
which makes it should fix and not must fix. Fix: run the installer in the background with `&` and
`wait`, remember its process number, and add `trap 'kill "$child" 2>/dev/null; cleanup; exit 143' TERM HUP`
so the installer is stopped before its folder is deleted.

## Nice to have

- `bootstrap/sirven-bootstrap.sh:61-72`: the shape checks are looser than `release.sh:60-66` (the tag glob
  accepts any characters after `v1.2.3`, the checksum check looks only at the first character and the
  length). Both fail closed today, so this is cosmetic; reuse the stricter charset test
  (`*[!0-9a-f]*` for the checksum, `*[!A-Za-z0-9.v-]*` for the tag).
- `sirven-bootstrap.sh:51`: add `--connect-timeout 20 --max-time 300`, and `--proto-redir '=https'` so a
  redirect cannot leave https (the checksum already covers integrity).
- `release.sh:89`: `grep '/install\.sh$'` matches any depth; match `^[^/]*/install\.sh$`. Line 101 rewrites
  the bootstrap non-atomically (`cat > file`); write to a temp file in the same folder and `mv`.
- `lib/layout.sh:83-86`: the guard `*/package` also matches `/package`; check the parent is `$STATE_DIR`.
  `cp -R` at line 90 also copies `__pycache__` folders and macOS extended attributes from a developer
  checkout; exclude them, and run `chmod -R go-w "$staging"` explicitly so the mode does not depend on the
  caller's umask. Today the copy is correct: parent `/var/lib/sirven` is mode 0700, copy files are 0644
  and folders 0755, owned by the installing user (root on a real install), so the agent account cannot
  modify the code root will run.
- `lib/preflight.sh:75`: `xcode-select -p` can print a path that no longer exists (a deleted Xcode);
  then the placeholder is not caught and the later `python3 --version` hits the shim's error. Also test
  `[ -d "$(xcode-select -p)" ]`. The "about 2 GB" figure at `preflight.sh:89` is not verified; say "a large
  download" or cite a source.
- `bin/sirven:150, 433, 469` call `python3` after only `command -v python3`, so on a Mac without the
  developer tools those entry points still open the system dialog. Not reachable until a Mac install can
  be applied, but call `preflight_python macos` there too when that changes.
- Documentation: `docs/BOOTSTRAP.md` step 1 should say to tag the merged commit on main, and recommend a
  GitHub tag protection rule so a pushed tag cannot be moved or deleted; the pin covers a moved tag, but
  protection turns a silent global outage into an impossible one.
- `make lint` should fail, not skip, when `shellcheck` is missing in the continuous-integration run.

## Answers to the questions asked

1. Bootstrap security: checksum is verified (`sirven-bootstrap.sh:81-84`) before `mkdir unpacked`/`tar -x`
   (lines 86-87) and before any execution; the empty pin refuses before any network call (lines 61-62);
   malformed pins refuse; a failed download stops via `|| fail`; `trap cleanup EXIT` is installed right
   after `mktemp` and removed the directory on success, mismatch, TERM and HUP; quoting is correct under
   `set -u` on bash 3.2 (`${1+"$@"}`, no arrays). The only hole is must fix 3. The unpinned shipped copy exits 1
   with a clear message and downloads nothing, so deploying it by mistake is a loud, safe outage.
2. `release.sh` computes the checksum of the same URL form the bootstrap downloads, so it is correct in
   normal use; see S2 for `--tarball` and archive stability. It cannot write a wrong pin silently except
   through `--tarball`, and the awk step refuses unless exactly one of each pin line exists.
3. SIR-51: location, mode and undo are sound (see Nice to have for the mode detail; uninstall from the
   copy was run for real and worked, and a folder without the marker is kept). The refresh gap is must fix 2, a
   must fix. Old installs without a copy get one on the next run, because the marker is absent.
4. SIR-50: detection asks `xcode-select -p` first and never runs the placeholder; verified end to end with
   fakes. The message is clear. Remaining edge cases are in Nice to have.
5. Tests: see S3.
6. `make test` and `make lint`: see the table above.

CHANGES REQUIRED, reviewed at 3381525 (the last product commit on this branch; this report is committed on top of it).

## Re-review of the fixes (tip d5ec263)

Reviewed: commits 9a9c94e, 23de433, 2d6897d, d5ec263 on branch
`sir-49-sir-50-sir-51-pin-the-bootstrap-keep-a-lo-thr_phgpsm8d7h`, in a scratch worktree of d5ec263 and
scratch copies of it. Parent decision applied: the pin targets a `git archive` tarball uploaded as a
GitHub release asset, and `--tarball` is gone. Bash for every run: `/bin/bash` 3.2.57. The real installer
was not run; installer runs used `--prefix` fake roots or `--dry-run`.

### Command results

| Command | Result |
| --- | --- |
| `make test` | exit 2, 409 passed, 3 failed: the same three known failures (`test_install_started_by_sh_says_to_use_bash`, `test_enter_twice_accepts_the_shown_defaults`, `test_input_that_ends_takes_the_defaults`). Outside the sandbox. |
| `make lint` | exit 0, `bash -n` on 57 files; `shellcheck` is still not installed, so it was skipped. |

### The three must-fix items: all resolved

**Must fix 1 (partial copy marked complete, installer deleting itself): resolved.**
- Source missing `uninstall.sh`: the step fails ("the package has no uninstall.sh to keep"), the old copy and its marker stay (`tag=v0.3.0` before and after), and `package.new` is cleaned up.
- Source with an unreadable `lib/phone_map.py` (a `cp` that fails midway): "could not copy lib", the step fails, the old copy stays; on a fresh root no `package` folder exists at all.
- Install run from the copy with the marker present: the plan prints "this package runs from its pinned copy ... already in place", 51 files before and after, marker unchanged. With the marker deleted: the copy keeps its other files (50 of 51; it is not repaired, but nothing is destroyed). The plan omits the copy step in this case (`plan_layout`), which is the behavior asked for.
- Uninstall run from the copy, for real: exit 0, the copy removes itself and `/var/lib` is left empty.
- The copy has no group or other write bits, and the `__pycache__` folders are excluded.

**Must fix 2 (copy never refreshed): resolved.**
- Same release again: "already done", applied 0 steps.
- New release (`v0.2.0` then `v0.3.0`): "to do", the copy is rebuilt, the stale file is gone, the marker reads `tag=v0.3.0`.
- Checkout installs: an edit to `lib/layout.sh` or `bin/sirven` in the source is detected (`diff -rq`) and the copy is rebuilt; an unchanged checkout is skipped.
- The new test `test_the_copy_from_a_newer_release_undoes_an_older_install` covers the reason the refresh matters.

**Must fix 3 (cut-off pipe drops the arguments): resolved.** Truncation sweep over every prefix of the
pinned bootstrap (5962 bytes), piped to `bash -s -- --dry-run --level observer`: only the complete script
(with and without its final newline) ran the installer, both with the full arguments. With no arguments,
the four prefixes that run it are the complete script and the cut at `main`, which is identical to the
full line. Arguments with spaces and an empty argument arrive intact.

### Should-fix items from the first review

- **Documentation promised a revoke that is refused: resolved.** `docs/BOOTSTRAP.md` now says revoke from the copy is not available in this alpha (dry run only, exit 3 when applied) and tells the reader to revoke by uninstalling. `lib/layout.sh` note and `docs/WALKTHROUGH.md` match.
- **Archive stability and `--tarball`: resolved by the parent decision.** I ran `release.sh v0.2.0` in a scratch clone with an annotated tag: it built the archive twice, wrote exactly the two pin lines (diff: 2 insertions, 2 deletions), the pinned checksum equals `shasum -a 256` of `dist/release/sirven-v0.2.0.tar.gz`, `dist/` is ignored by git, and the printed upload command names the file with the exact basename the bootstrap downloads (`sirven-TAG.tar.gz`). A missing tag exits 1, `main` exits 1, `--tarball` and no arguments print usage (64). Round trip: that pinned bootstrap, piped to `bash -s -- --dry-run`, with a fake `curl` serving the built asset, verified the checksum, unpacked, and ran the real `install.sh` through its preflight (its later Tailscale conflict is this machine's own state, not the bootstrap). A test (`test_the_bootstrap_and_the_release_step_agree_on_the_repository_and_the_asset`) now ties the two files together.
- **Test gaps: mostly resolved.** I mutated copies of the tree and ran the relevant test files:
  - checksum compared after `tar -x`: now fails `test_the_checksum_is_checked_before_the_archive_is_unpacked`
  - `--proto/--tlsv1.2/--proto-redir` removed, and separately the timeouts removed: both fail `test_the_download_uses_https_only_with_timeouts`
  - argument guard removed: fails `test_a_download_cut_off_in_its_last_line_runs_nothing`
  - TERM and HUP trap removed: fails `test_stopping_the_bootstrap_stops_its_installer_and_removes_the_folder`
  - cleanup trap removed: fails two tests
  - run-from-copy handling removed from the plan: fails `test_the_installer_run_from_its_copy_never_deletes_it`
  - skip check reverted to "marker exists": fails two tests
  
  Two mutations still pass, see New should fix 2.
- **Documentation for Macs: resolved** (WALKTHROUGH and BOOTSTRAP now say a Mac does not apply an install in this alpha, and the copy is created on Linux only).
- **Direct kill leaves the installer running: partly resolved.** See New should fix 1.

### New findings introduced by the fixes

**New should fix 1. Every process the installer starts now ignores Ctrl-C (`bootstrap/sirven-bootstrap.sh`, the `bash "$installer" ... &` line).**
A non-interactive shell starts background commands with SIGINT ignored, and children inherit "ignored". Reproduced: a fixture installer that prints its child's SIGINT disposition printed `1` (ignored) when run through the new bootstrap, and the default handler when run in the foreground. Consequences: the installer shell itself is stopped correctly (Ctrl-C on a terminal exits 130, TERM exits 143, the temp folder is removed, and the installer does not read the terminal wrongly: a prompt answered through `/dev/tty` works from the background, exit status 7 passes through). But a step in flight when the signal arrives, such as a `python3` run or a long `tailscale` or `useradd` call, no longer receives the interrupt and runs to completion on its own, after the installer shell that would record its undo is gone. Reproduced with a direct TERM: the installer shell died, its child `sleep` survived, reparented to process 1. Before this fix a Ctrl-C reached those children. The window is one step, and a Mac only dry-runs today, so I rank it should fix and not must fix, but it is cheap: in `stop_installer`, also stop the installer's descendants before the installer itself (for example a small recursive `pgrep -P` walk, then `kill`), and add a test whose fixture starts a background child and asserts it is gone. Update the sentence in `docs/BOOTSTRAP.md` ("the installer is stopped too") to say "and its running steps".

**New should fix 2. Two tests are blind to the properties they are named for.**
- `test_a_failed_copy_leaves_no_package_folder_and_no_marker` induces its failure by removing `lib/` from the source, which the new up-front `[ -e ]` check catches. Mutation: replace the required-item `cp ... || { ...; return 1; }` (`lib/layout.sh:115`) with `cp ... 2>/dev/null`: 45 passed, 0 failed. The behavior is correct today (reproduced above with an unreadable file), but nothing protects it. Add a test with an unreadable file inside `lib/` (skip when the tests run as root).
- `test_the_kept_copy_has_no_group_or_other_write_bits` installs from a checkout whose files are already 0644, so removing `chmod -R go-w "$staging"` passes (45 passed). Make the source file group-writable first (`chmod g+w`) and assert it is not in the copy.
- The copy-from-copy guard inside `layout_keep_package` (defense in depth behind the plan-level handling) has no direct test: removing it passes. Call `layout_keep_package` with the copy as source.

### Nice to have, new

- `lib/layout.sh:132-135`: `rm -rf "$destination"` then `mv "$staging" "$destination"` leaves a moment with no copy; `mv destination destination.old`, `mv staging destination`, `rm -rf destination.old` keeps one at all times. Also, a `package.new` left by a killed install makes uninstall keep `/var/lib/sirven` ("it holds files this package did not create"); reproduced. Have uninstall's undo remove `package.new`, or accept it because the next install run removes it.
- `bootstrap/release.sh`: `--verify-tag` only proves the tag exists on GitHub, not that it is the commit the local tag points to. Compare `git ls-remote origin "refs/tags/$tag^{}"` with `git rev-parse "$tag^{commit}"` before building, and say so in the printed steps.
- `shellcheck` is still not installed here; run the repository's `make lint` where it is before merging.

### Regression hunt, items that held

- Staged rename: failure paths clean up `package.new`; the old copy survives a failed refresh; `mv` is a same-folder rename.
- Argument guard: no effect on a normal run, an empty argument list, or arguments with spaces; fails closed on every truncation.
- Signal handling: TERM and HUP exit 143, Ctrl-C on a real terminal (run through a pseudo-terminal) exits 130, the temp folder is always removed, the installer's exit status is returned, and interactive questions still work from the background installer.
- Bootstrap download flags, timeouts and the stricter pin checks behave as documented; a pin of `a` followed by 63 `z` is now refused before any download.

### Verdict

**APPROVE**, at tip `d5ec263`. Remaining must-fix items: none. Recommended before merge (small): New should fix 1 (descendants of the installer survive a stop) and the two blind tests in New should fix 2. This re-review is committed on top of `aedf880`.
