# sirven walkthrough

sirven gives your personal agent its own account on your machine, with an access level you pick. You can see every grant, roll back the last change, or revoke everything at any time. No hosted middleman: the agent runs as a local user you own.

The whole setup is three steps and a confirmation.

## already running an agent? that is the headline case

sirven is built for people who already have a personal agent or muse running (a coding agent, a chat runtime, your own setup). It does not replace any of it. sirven connects the pieces that are missing: the dedicated account, the access level, the audit trail, the kill switch. Anything you already have stays exactly as it is; your agent just plugs into the account sirven creates.

The installer checks first and adopts what it finds instead of installing it again:

- **Tailscale.** Installed, logged in, and this machine's own tags are read from `tailscale status --json`. A machine already logged in with `tag:agent` is the agent node: the plan skips the auth key and the join, and never runs `tailscale up` on it. A machine that is installed but not logged in has no login to adopt: its install is kept, and the join is the usual fresh setup step (see the next section). sirven never logs Tailscale in or out, re-keys it, re-tags it, or changes its settings in an adopt path; the one login it ever logs out is a node its own join made and recorded.
- **bb.** Found on the path, it is kept as it is, and `--with-bb` has nothing left to install.
- **An earlier sirven run.** The grant in force, the policy copy, the audit log, and the install record are kept. A level or path you leave open is taken from the grant in force, so a plain re-run keeps what you set up before.

Each thing it keeps gets an `adopted:` line at the top of the plan, and `--dry-run` shows all of it while changing nothing. When what is there cannot be kept alongside what you asked for, the installer stops before any change, says what conflicts, and says what you can do:

- this machine is logged in to Tailscale without `tag:agent` and you asked for the Tailscale transport (run again with `--transport none`, or tag the machine yourself in the Tailscale admin console);
- a grant is in force and you asked to grant no path (keep it, or use the kill switch);
- the installed policy for your level differs from the one in `levels/` (sirven will not overwrite a hand edit);
- the grant record cannot be read, or the audit log belongs to a different owner than `--owner`.

## The Tailscale join, and how it is undone

With `--transport tailscale` (the default) a real apply on Linux, inside a throwaway container, brings the machine onto your tailnet as the tagged agent node. You make one auth key in the Tailscale admin console (settings, keys): tagged `tag:agent`, pre-approved, and ephemeral if you can, because an ephemeral node leaves the tailnet by itself when it logs out. Give it to the installer one of two ways, and use the file first, because it is the safer one: save it as `/etc/sirven/tailscale-auth-key`, a plain file owned by root with mode 0600, one name only, and no extended access control list (a file with any permission for the group or others, owned by another account, with an access control list entry for another account whatever the mask shows, with a second name (a hard link), or a link, is refused, not used); a saved file is removed after the join. Or hand it over in the environment as `SIRVEN_TAILSCALE_AUTHKEY` (or `TAILSCALE_AUTHKEY`). Through sudo that needs `sudo --preserve-env=SIRVEN_TAILSCALE_AUTHKEY`, and sudo allows that only when its policy does (the policy is the sudoers file, which says what sudo may do): a rule for all commands implies the `SETENV` tag, a narrower rule needs that tag, or an `env_keep` line naming the variable. When the policy does not allow it, sudo may refuse the whole command with an error. Plain `sudo` without the option drops the variable, and the join then stops with "there is no Tailscale auth key". The installer takes both variables out of its own environment as the first thing it does and hands the key only to the join step, so no other step, before or after the join, and no run where the join is skipped, starts a child process that inherits it. What it cannot do is scrub the block of the environment a process was started with: root can read that in `/proc/<process number>/environ` while the process runs, for the installer and for the two short-lived processes it hands the key to, so the key file is the only route that never puts the key in an environment. The key is never put on a command line (tailscale reads it from a private temporary file), never written to the audit log, the install record, or any other file, and blanked out of anything tailscale prints.

What the join runs: `tailscale up --auth-key=file:<private copy> --advertise-tags=tag:agent --hostname=agent-<this machine's name> --ssh=false --accept-dns=false --accept-routes=false --reset --timeout=60s`. Tailscale SSH stays off (no level grants it), no exit node is used, and no routes or name resolution settings are accepted. It then records the node it joined (node number, host name, tag, never the key) in `/var/lib/sirven/tailscale-node.json`, root only.

Refused before any change, with what to do (the installer makes all of these checks before its first step): no key; a saved key file that is not a plain file owned by root with no permission for anyone else and no extended access control list (the mode bits alone cannot show one: on Linux a mask of `---` hides an entry for another account from them, so the check looks for the list itself); a key with characters no key has (a carriage return from Windows line ends, say); tailscale not installed (the message names the download page and the Debian package repository); tailscaled not answering; a tailscale too old to read a key from a file. A second apply finds the node already logged in with `tag:agent` and does nothing, and needs no key. A machine already logged in without `tag:agent` is refused, never re-tagged.

Undo, by `install.sh revoke --all` and by `uninstall.sh` (the install record carries the same undo): `tailscale logout`, and only when this machine's login is still the exact node the record names and it still has `tag:agent`. A login someone else made, or any other node of your tailnet, is never touched; the stale record is dropped and the run says so. With an ephemeral key the node leaves the tailnet at once; with any other key the machine entry stays listed (expired) in the admin console until you delete it, and the revoke plan says so. If tailscaled does not answer, the logout fails loudly, the record stays, and the run can be repeated. If tailscale is gone, there is nothing to log out and the record is dropped. Revoke then uninstall works: uninstall finds the record already gone. A join that logs in but does not reach Running (a tagged key that is not pre-approved ends in `NeedsMachineAuth`) fails the install and leaves the login and its record: `revoke --all` and `uninstall.sh` log that node out too, because they act on the record file whether or not the install record has a line for it. A copy of the key left by a join that was killed is removed by the next join, by the logout, and by uninstall.

Real macOS machines and Linux machines outside a container stay plan only for the install (the installer refuses to apply there); the kill switch logout runs on a real Linux machine like the rest of the kill switch.

Asking for a different level or path on purpose is not a conflict: the plan says the grant in force changes, and `sirven grant rollback` reverses it.


## 1. get the package

```bash
git clone https://github.com/Joesirven/sirven.git
cd sirven
```

Or from npm: `npm install -g @joesirven/sirven`, then run the `install.sh` inside the global package folder.

On a Mac without the command line developer tools, the installer stops with a message asking you to run `xcode-select --install` first: the python3 that macOS ships is a placeholder until they are installed. Install them, wait for that to finish, and run the installer again. Applying an install to a Mac is not verified yet: a real run stops before any change, and on a Mac with the developer tools a `--dry-run` shows the plan.

The one-line command at `https://cli.sirven.xyz` installs a pinned release instead, checked against its checksum before anything runs. See [BOOTSTRAP.md](BOOTSTRAP.md).

## 2. run the installer

```bash
sudo bash install.sh
```

The installer prints the full plan first, then asks at most two questions, each with a default shown:

- **level**: `observer` (default), `builder`, or `operator`. See `levels/` for exactly what each one allows.
- **path**: the folder the agent may work in. Default is the current folder when it can be granted.

Answer them, or take the defaults. With `--yes` nothing is asked: observer, no path. With `--dry-run` the plan is printed and nothing changes.

## 3. confirm

Confirm the plan and the installer applies it: it creates the service user (this is the one step that needs sudo), sets the access level on the path, and writes an audit record. Nothing else on the machine changes.

## connect your agent

Point your agent or muse at the new service user: each runtime gets its own login for that account. The installer never copies your personal credentials across. After that, your agent works inside the level you granted. The audit log already records the install and every grant change; live per-session and per-command logging ships through the forced-command wrapper (designed, not built yet).

## check it any time

```bash
sirven grant inspect            # the level in force and the active grants
sirven grant rollback --dry-run # what reversing the last change would do
```

`inspect` only reads. `rollback` without `--dry-run` prints the same plan and then applies it.

## take it all back

```bash
sudo /usr/local/sbin/sirven revoke --all
```

The kill switch. Cuts the agent off in one shot: ends its processes, locks and expires its account, removes its keys, services and
jobs, and takes back every grant. It keeps the records so you can look at what happened, and it asks you to type `revoke` first
(`--yes` skips the question). It works on a real machine, not only in a container. Run it through the launcher, `sudo /usr/local/sbin/sirven revoke --all`, which runs the root-owned kept copy, so code the agent
could have edited never runs as root. Install lays the launcher down. Delete the folder you unpacked the package in, or grant a path that does not hold it.
A plain install will not turn the account back on; `install.sh --reinstate` does, on purpose.

## known limitations, not built yet

- Today the audit log covers the install record and grant changes. Once the forced-command wrapper lands, "every session and command you send is logged" becomes the accurate claim. Kernel-level auditing of everything the agent's processes do is designed, not built.
- macOS protects Desktop, Documents, and Downloads behind privacy prompts that a service account cannot answer. Grant paths outside those folders for now.
- Tests so far prove plans, not effects. Real user creation is verified in throwaway environments only.
- Friend invite (a friend's agent on your machine) ships last: read-only by default, with mandatory expiry.
