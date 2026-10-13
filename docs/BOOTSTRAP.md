# The one-line installer and its pinned release

The command on the download page, `curl -fsSL https://cli.sirven.xyz | bash`, runs a short script
served at cli.sirven.xyz. The script does not install anything from the repository's main branch.
It installs one release, chosen by the maintainer, and checks that release's checksum before it
unpacks or runs anything.

## What the script does

1. Downloads the release tarball for one git tag, from GitHub's archive of that tag, over https only.
2. Computes the tarball's checksum (a 256-bit secure hash, printed by `shasum -a 256` on macOS or
   `sha256sum` on Linux) and compares it with the checksum pinned in the script.
3. On a match, unpacks the tarball into a fresh temporary folder, runs that release's `install.sh`
   with the arguments you passed, and deletes the folder when it ends.

On a mismatch it stops, says what it expected and what it downloaded, and runs nothing. A failed
download also runs nothing. A script with no release pinned refuses to download at all.

The script is `bootstrap/sirven-bootstrap.sh`. Read it before you run it.

## Where the pin lives

The release pin is two lines at the top of `bootstrap/sirven-bootstrap.sh`:

```
SIRVEN_PINNED_TAG="v0.2.0"
SIRVEN_PINNED_SHA256="<64 hexadecimal characters>"
```

The served script carries its own pin, so nothing is fetched from anywhere to find out which
release to install. Only `bootstrap/release.sh` writes these two lines.

## Releasing: what the maintainer runs

Publishing a release is a deliberate act with three outside steps, and the script does only the
middle one.

1. Create and push the tag. Nothing downloads the tag until it is on GitHub.

   ```
   git tag -a v0.2.0 -m "sirven 0.2.0"
   git push origin v0.2.0
   ```

2. Pin it. This downloads the tag's tarball, computes its checksum, and writes the two pin lines.

   ```
   bash bootstrap/release.sh v0.2.0
   ```

   To pin from a tarball already on disk, add `--tarball FILE`. The script changes only the two pin
   lines and prints the checksum and the next steps.

3. Review, merge, and deploy the script. Commit `bootstrap/sirven-bootstrap.sh` on a branch and merge
   it to main, so the file the server serves is in git. Then copy it to the file the server serves
   at cli.sirven.xyz and deploy that server. Check the served bytes match the repository copy:

   ```
   curl -fsSL https://cli.sirven.xyz | cmp - bootstrap/sirven-bootstrap.sh
   curl -fsSL https://cli.sirven.xyz | bash -s -- --dry-run
   ```

Until step 3 is done, cli.sirven.xyz serves whatever was deployed last. Do not deploy a pin before
its tag is pushed: the bootstrap would refuse with a download error, and nothing would be run.

## The copy kept after install

A real install keeps a copy of the package it ran from, under `/var/lib/sirven/package`:
`install.sh`, `uninstall.sh`, `bin`, `lib`, `levels`, `components`, and `project.json`. A marker
file in the copy records the release tag and checksum it came from, or `unpinned` when the
installer ran from a repository checkout.

Revoking access and uninstalling then need no download and no repository:

```
sudo bash /var/lib/sirven/package/install.sh revoke --all
sudo bash /var/lib/sirven/package/uninstall.sh
```

Uninstall removes the copy along with everything else the install created. A re-run of the
installer keeps the copy it already has, so a copy from an older release stays until uninstall.
