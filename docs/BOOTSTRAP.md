# The one-line installer and its pinned release

The command on the download page, `curl -fsSL https://cli.sirven.xyz | bash`, runs a short script
served at cli.sirven.xyz. The script does not install anything from the repository's main branch.
It installs one release, chosen by the maintainer, and checks that release's checksum before it
unpacks or runs anything.

## What the script does

1. Downloads the release archive attached to one GitHub release, over https only, with timeouts.
2. Computes the archive's checksum (a 256-bit secure hash, printed by `shasum -a 256` on macOS or
   `sha256sum` on Linux) and compares it with the checksum pinned in the script.
3. On a match, unpacks the archive into a fresh temporary folder, runs that release's `install.sh`
   with the arguments you passed, and deletes the folder when it ends.

On a mismatch it stops, says what it expected and what it downloaded, and runs nothing. A failed
download also runs nothing. A script with no release pinned refuses to download at all.

If the download is cut off partway, the script runs nothing and says so. If the script itself is
stopped while the installer runs (a signal from a terminal or from `kill`), the installer and every
process it started, such as a running python3 or useradd step, are stopped too, before the folder is
deleted.

The script is `bootstrap/sirven-bootstrap.sh`. Read it before you run it.

## Handing the Tailscale auth key to the installer

The script passes its arguments on and starts the installer in the environment it was started in, so a
Tailscale auth key reaches the join in one of two ways. The default is a key file: save the key as
`/etc/sirven/tailscale-auth-key`, owned by root, mode 0600, with no extended access control list (a
file with any extra access entry for another account is refused, even when the mode bits look right).
The key then never passes through sudo or your shell history, and the installer removes the file after
the join. To make the file without the key appearing on a command line:

```
sudo install -d -m 0755 -o root -g root /etc/sirven
sudo sh -c 'umask 077; cat > /etc/sirven/tailscale-auth-key'
```

Paste the key, press Return, then Ctrl-D.

The other way is the environment: `SIRVEN_TAILSCALE_AUTHKEY` (or `TAILSCALE_AUTHKEY`) set in your shell
and kept through sudo with `sudo --preserve-env=SIRVEN_TAILSCALE_AUTHKEY`. Sudo allows that only when
its policy does (the sudoers file, which says what sudo may do): a rule for all commands implies the
`SETENV` tag, a narrower rule needs that tag, or an `env_keep` line naming the variable. When the policy
does not allow it, sudo may refuse the whole command with an error. Plain `sudo` without the option
drops the variable, and the installer then refuses with "there is no Tailscale auth key", changing
nothing. Read the key into the variable with `read -rs SIRVEN_TAILSCALE_AUTHKEY; export SIRVEN_TAILSCALE_AUTHKEY`, not
`SIRVEN_TAILSCALE_AUTHKEY=<the key> command`, since a command line is kept in shell history and shows
in the process list. When the plan joins, the installer unsets both variables as soon as the join step has run. A machine that is already the agent node has no join step, and the key stays in the environment there; use the file.

## Where the pin lives

The release pin is two lines near the top of `bootstrap/sirven-bootstrap.sh`:

```
SIRVEN_PINNED_TAG="v0.1.0"
SIRVEN_PINNED_SHA256="556ce5fb658c6d6f1e0fa74de39c4d6c4508c61f65ac51dd52c3feda914a2718"
```

Those are the values for release v0.1.0, as pinned at the time of writing. Read the current pins in the script itself.

The served script carries its own pin, so nothing is fetched from anywhere to find out which
release to install. Only `bootstrap/release.sh` writes these two lines.

The archive is built by `bootstrap/release.sh` with `git archive` from the tag's commit, and that
file is what gets uploaded. GitHub does not promise that its generated tag archives keep their
bytes, so the bootstrap never uses them.

## Releasing: what the maintainer runs

Publishing a release has an outside step (the upload) that only the maintainer runs. The script
builds and pins, and prints the upload command without running it.

1. Create the tag on the merged commit, on main, and push it.

   ```
   git tag -a v0.2.0 -m "sirven 0.2.0"
   git push origin v0.2.0
   ```

   Protect release tags in the repository settings, so a pushed tag cannot be moved or deleted.

2. Build and pin. This builds `dist/release/sirven-v0.2.0.tar.gz`, builds it a second time and
   checks the bytes repeat, checksums it, and writes the two pin lines.

   ```
   bash bootstrap/release.sh v0.2.0
   ```

3. Upload the file the script checksummed, as a release asset. The command is printed for you, and
   it is the one place the release is published:

   ```
   gh release create v0.2.0 dist/release/sirven-v0.2.0.tar.gz --repo Joesirven/sirven --verify-tag --title "sirven v0.2.0"
   ```

   Then check the uploaded bytes against the pin, with the URL the bootstrap uses:
   `https://github.com/Joesirven/sirven/releases/download/v0.2.0/sirven-v0.2.0.tar.gz`.

4. Review, merge, and deploy the script. Commit `bootstrap/sirven-bootstrap.sh` on a branch and merge
   it to main, so the file the server serves is in git. Then copy it to the file the server serves
   at cli.sirven.xyz and deploy that server. Check the served bytes match the repository copy:

   ```
   curl -fsSL https://cli.sirven.xyz | cmp - bootstrap/sirven-bootstrap.sh
   curl -fsSL https://cli.sirven.xyz | bash -s -- --dry-run
   ```

Until step 4 is done, cli.sirven.xyz serves whatever was deployed last. Do not deploy a pin before
its release asset is uploaded: the bootstrap would refuse with a download error, and nothing would
be run.

## The copy kept after install

A real install keeps a copy of the package it ran from, under `/var/lib/sirven/package`:
`install.sh`, `uninstall.sh`, `bin`, `lib`, `levels`, `components`, and `project.json`. A marker
file in the copy records the release tag and checksum it came from, or `unpinned` when the
installer ran from a repository checkout.

Each install run checks the copy. When it came from another release, or from a checkout whose files
changed, the copy is rebuilt beside the old one and moved into place only when it is complete. A
partial copy never replaces a working one. Uninstall reverses the install record with the copy, so
the copy must always be the release that made the record, or a later release that can still undo it.

Uninstalling needs no download and no repository:

```
sudo /usr/local/sbin/sirven uninstall
```

To cut the agent off now and keep every record, run the kill switch from the copy:
`sudo /usr/local/sbin/sirven revoke --all` (add `--dry-run` to read the plan first).
It applies on Linux, in a container and on a real machine, and asks you to type `revoke` first (`--yes` skips the question);
on a Mac it is still plan output and exits with status 3 when applied.

A Mac does not yet apply an install by default, so no copy is made on a Mac either. The copy is
created on Linux (a container or a real machine, as root). A real Mac apply is switched off unless the
owner sets `SIRVEN_MACOS_REAL_APPLY=1` as root for the real install check
(see `docs/research/qa/macos-real-apply-prep.md`).
