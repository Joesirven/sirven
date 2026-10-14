# sirven walkthrough

sirven gives your personal agent its own account on your machine, with an access level you pick. You can see every grant, roll back the last change, or revoke everything at any time. No hosted middleman: the agent runs as a local user you own.

The whole setup is three steps and a confirmation.

## already running an agent? that is the headline case

sirven is built for people who already have a personal agent or muse running (a coding agent, a chat runtime, your own setup). It does not replace any of it. sirven connects the pieces that are missing: the dedicated account, the access level, the audit trail, the kill switch. Anything you already have stays exactly as it is; your agent just plugs into the account sirven creates.

The installer checks first and adopts what it finds instead of installing it again:

- **Tailscale.** Installed, logged in, and this machine's own tags are read from `tailscale status --json`. A machine already logged in with `tag:agent` is the agent node: the plan skips the auth key and the join, and never runs `tailscale up` on it. A machine that is installed but not logged in has no login to adopt: its install is kept, and the join is the usual fresh setup step, which stays plan only. sirven never logs Tailscale in or out, re-keys it, re-tags it, or changes its settings in an adopt path.
- **bb.** Found on the path, it is kept as it is, and `--with-bb` has nothing left to install.
- **An earlier sirven run.** The grant in force, the policy copy, the audit log, and the install record are kept. A level or path you leave open is taken from the grant in force, so a plain re-run keeps what you set up before.

Each thing it keeps gets an `adopted:` line at the top of the plan, and `--dry-run` shows all of it while changing nothing. When what is there cannot be kept alongside what you asked for, the installer stops before any change, says what conflicts, and says what you can do:

- this machine is logged in to Tailscale without `tag:agent` and you asked for the Tailscale transport (run again with `--transport none`, or tag the machine yourself in the Tailscale admin console);
- a grant is in force and you asked to grant no path (keep it, or use the kill switch);
- the installed policy for your level differs from the one in `levels/` (sirven will not overwrite a hand edit);
- the grant record cannot be read, or the audit log belongs to a different owner than `--owner`.

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
sudo bash install.sh revoke --all --dry-run
```

The kill switch prints its plan: every grant it would remove. Applying it is not built yet, and an applied run is refused with exit status 3 before it changes anything. Neither the kill switch nor uninstall is verified to apply on a regular machine yet. Until one is, check what the agent can reach with `sirven grant inspect`.

## known limitations, not built yet

- Today the audit log covers the install record and grant changes. Once the forced-command wrapper lands, "every session and command you send is logged" becomes the accurate claim. Kernel-level auditing of everything the agent's processes do is designed, not built.
- macOS protects Desktop, Documents, and Downloads behind privacy prompts that a service account cannot answer. Grant paths outside those folders for now.
- Tests so far prove plans, not effects. Real user creation is verified in throwaway environments only.
- Friend invite (a friend's agent on your machine) ships last: read-only by default, with mandatory expiry.
