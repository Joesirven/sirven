# Code review: SIR-49, SIR-50, SIR-51

Reviewed: `git diff origin/main...HEAD` on branch `code-review-pinned-bootstrap-local-copy-python3-thr_s3x48myuig`,
commits 4125b15 (pinned bootstrap), 612e17a (python3 placeholder guidance), 8e75f72 (kept copy of the
package), 3381525 (documentation). Reviewed inline by one reviewer with a separate verification pass:
every finding below was reproduced by running code, not only read. No workflow run was used (the
capacity tool gave no reading for this machine), and nothing was run as root or against the real Mac.

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
| Bootstrap, SIGTERM and SIGHUP to the bootstrap while the installer runs | temp directory removed. SIGINT could not be tested honestly from a background job (a non-interactive shell ignores it there), so Ctrl-C cleanup is unverified. |
| Truncation sweep, every prefix length of the pinned bootstrap piped to `bash -s -- --dry-run` | 5 of 4360 prefixes ran the installer; see M3. |
| `install.sh --dry-run` as macOS with a fake `xcode-select` (exit 2) and a fake placeholder `python3` | stopped with the xcode-select message; the fake `python3` was never run (marker file absent). |
| `codeload.github.com/.../refs/heads/main` downloaded twice, and the `github.com/.../archive/...` form once | identical bytes (same checksum) in all three. |

## Must fix

### M1. A failed or partial copy is marked complete, and the installer can delete itself

`lib/layout.sh:81-93` (`layout_keep_package`), run from `lib/plan.sh:407`.

`plan_apply` runs each action as `if ! ( eval "$action" )`. Inside that construct `set -e` is off, so a
failing `cp -R` in the loop at `lib/layout.sh:89-91` is ignored, and the last command, the marker write
at line 92, succeeds. The step then reports "done" and records its undo. The skip check
(`[ -f $copy/PINNED-COPY ]`, `lib/layout.sh:124`) trusts the marker, so every later run skips the broken
copy.

Reproduced: with `components/` missing from the source, `layout_keep_package` printed
`cp: ... components: No such file or directory`, returned success, and left a directory holding
`PINNED-COPY` without `components`. A full disk or an interrupted copy does the same.

Second symptom of the same code: `rm -rf "$destination"` at line 86 runs before the copy. Running the kept
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
5. Make the skip check at line 124 prove completeness too (see M2), not only that the marker exists.
6. Add tests: a source missing one item must make the step fail and leave no `package` folder; running
   the installer from the copy must not shrink it.

### M2. A re-run or upgrade keeps the old copy for ever; judged as must fix before release

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

Fix: make the check compare identity. Replace the check with a command that succeeds only when the marker
holds the current tag and checksum and is not `unpinned`, for example
`grep -qx "tag=${SIRVEN_PACKAGE_TAG:-unpinned}" marker && grep -qx "sha256=${SIRVEN_PACKAGE_SHA256:-unpinned}" marker`.
For the `unpinned` (checkout) case, either always refresh, or compare the files with `diff -r`. A refresh
goes through the staging-and-move path from M1, so a failed refresh keeps the old working copy. Update the
sentence in `docs/BOOTSTRAP.md` and the comment at `lib/layout.sh:126`, and replace the test with
"a re-run from a different release replaces the copy", "a re-run from the same release leaves it".

### M3. A pipe cut inside the last line runs the installer without the user's arguments

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

### S1. The documentation promises a revoke that the installer refuses to apply

`docs/BOOTSTRAP.md:73-77`, `lib/layout.sh:129` (the note "later, without this repository: sudo bash ...
revoke --all"), `docs/WALKTHROUGH.md:73`.

Reproduced: `bash <copy>/install.sh revoke --all --prefix <fake root>` exits 3 ("the kill switch is plan
output in the alpha cut; apply comes in alpha + 1"). Only the dry run works, and uninstall from the copy
does work (exit 0, the copy removes itself). Fix: say in `docs/BOOTSTRAP.md` that revoke prints its plan
in the alpha and uninstall is applied, and keep the `layout.sh:129` note worded as future ("later", as it
is) but not as a working path.

### S2. The pin depends on GitHub keeping its archive bytes stable, and `release.sh --tarball` can pin bytes GitHub never serves

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

### S3. Test gaps: several checks could be removed without a failing test

`tests/unit/test_bootstrap.sh`, `tests/unit/test_install.sh`.

- No test runs the bootstrap the way users do (`bash -s -- ARGS < file`); every test uses `bash FILE`.
  So the truncation defect (M3), the standard-input handling and the `</dev/null` behavior are untested.
- Mismatch test (`test_mismatched_checksum_runs_nothing`) proves the installer did not run, but it would
  still pass if the checksum were compared after `tar -x`. The claim "checked before anything is
  unpacked" has no test. Give the fixture a tarball that `tar` cannot read: with the check before the
  unpack the error is the mismatch, otherwise it is a tar error.
- The fake curl ignores its flags, so removing `--proto '=https' --tlsv1.2` (`sirven-bootstrap.sh:51`)
  breaks nothing. Log the arguments and assert them.
- There is no round trip: `release.sh` pins a fixture, then that pinned file runs against the same
  bytes. That test is the one that catches "release.sh computes a different checksum than the bootstrap".
- No test for a temp directory left behind after success, mismatch or failed download.
- SIR-51: no test for a partial copy, copy-from-copy (M1), refresh on a new release (M2, and the current
  test asserts the opposite), or the mode of the copy.
- Positive: the SIR-50 tests are sound. The placeholder test fails if the check is removed, because the
  fake `python3` leaves a marker file; the Homebrew and developer-tools-present cases are covered.

### S4. Documentation accuracy for Macs

`docs/WALKTHROUGH.md:36`. The sentence "the installer stops and asks you to run `xcode-select --install`"
is true only with `--dry-run` or `--prefix`: on a real Mac without `--dry-run`, `install.sh` stops earlier
with "applying to a real macos machine is not verified yet" (`lib/plan.sh:322`, called before preflight
at `install.sh:289-293`). Since a Mac cannot apply at all yet, the kept copy of the package (SIR-51) is
never created on a Mac either; say so in `docs/BOOTSTRAP.md` so nobody expects it.

## Nice to have

- `bootstrap/sirven-bootstrap.sh:61-72`: the shape checks are looser than `release.sh:60-66` (the tag glob
  accepts any characters after `v1.2.3`, the checksum check looks only at the first character and the
  length). Both fail closed today, so this is cosmetic; reuse the stricter charset test
  (`*[!0-9a-f]*` for the checksum, `*[!A-Za-z0-9.v-]*` for the tag).
- `sirven-bootstrap.sh:51`: add `--connect-timeout 20 --max-time 300`, and `--proto-redir '=https'` so a
  redirect cannot leave https (the checksum already covers integrity).
- `release.sh:89`: `grep '/install\.sh$'` matches any depth; match `^[^/]*/install\.sh$`. Line 101 rewrites
  the bootstrap non-atomically (`cat > file`); write to a temp file in the same folder and `mv`.
- `lib/layout.sh:84`: the guard `*/package` also matches `/package`; check the parent is `$STATE_DIR`.
  `cp -R` at line 90 also copies `__pycache__` folders and macOS extended attributes from a developer
  checkout; exclude them, and run `chmod -R go-w "$staging"` explicitly so the mode does not depend on the
  caller's umask. Today the copy is correct: parent `/var/lib/sirven` is mode 0700, copy files are 0644
  and folders 0755, owned by the installing user (root on a real install), so the agent account cannot
  modify the code root will run.
- `lib/preflight.sh:78-83`: `xcode-select -p` can print a path that no longer exists (a deleted Xcode);
  then the placeholder is not caught and the later `python3 --version` hits the shim's error. Also test
  `[ -d "$(xcode-select -p)" ]`. The "about 2 GB" figure at `preflight.sh:88` is not verified; say "a large
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
   `set -u` on bash 3.2 (`${1+"$@"}`, no arrays). The only hole is M3. The unpinned shipped copy exits 1
   with a clear message and downloads nothing, so deploying it by mistake is a loud, safe outage.
2. `release.sh` computes the checksum of the same URL form the bootstrap downloads, so it is correct in
   normal use; see S2 for `--tarball` and archive stability. It cannot write a wrong pin silently except
   through `--tarball`, and the awk step refuses unless exactly one of each pin line exists.
3. SIR-51: location, mode and undo are sound (see Nice to have for the mode detail; uninstall from the
   copy was run for real and worked, and a folder without the marker is kept). The refresh gap is M2, a
   must fix. Old installs without a copy get one on the next run, because the marker is absent.
4. SIR-50: detection asks `xcode-select -p` first and never runs the placeholder; verified end to end with
   fakes. The message is clear. Remaining edge cases are in Nice to have.
5. Tests: see S3.
6. `make test` and `make lint`: see the table above.
