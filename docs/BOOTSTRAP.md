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

## Where the pin lives

The release pin is two lines near the top of `bootstrap/sirven-bootstrap.sh`:

```
SIRVEN_PINNED_TAG="v0.2.0"
SIRVEN_PINNED_SHA256="<64 hexadecimal characters>"
```

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
sudo bash /var/lib/sirven/package/uninstall.sh
```

To cut the agent off now and keep every record, run the kill switch from the copy:
`sudo bash /var/lib/sirven/package/install.sh revoke --all` (add `--dry-run` to read the plan first).
It applies on Linux inside a container; on a Mac it is still plan output and exits with status 3 when applied.

A Mac does not yet apply an install in this alpha, so no copy is made on a Mac either. The copy is
created on Linux, inside the container the installer supports.
