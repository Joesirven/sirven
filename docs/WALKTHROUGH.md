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

With `--transport tailscale` (the default) a real apply on Linux, inside a throwaway container, brings the machine onto your tailnet as the tagged agent node. You make one auth key in the Tailscale admin console (settings, keys): tagged `tag:agent`, pre-approved, and ephemeral if you can, because an ephemeral node leaves the tailnet by itself when it logs out. Give it to the installer one of two ways, and use the file first, because it is the safer one: save it as `/etc/sirven/tailscale-auth-key`, a plain file owned by root with mode 0600, one name only, and no extended access control list (a file with any permission for the group or others, owned by another account, with an access control list entry for another account whatever the mask shows, with a second name (a hard link), or a link, is refused, not used); a saved file is removed after the join. Or hand it over in the environment as `SIRVEN_TAILSCALE_AUTHKEY` (or `TAILSCALE_AUTHKEY`). Through sudo that needs `sudo --preserve-env=SIRVEN_TAILSCALE_AUTHKEY`, and sudo allows that only when its policy does (the policy is the sudoers file, which says what sudo may do): a rule for all commands implies the `SETENV` tag, a narrower rule needs that tag, or an `env_keep` line naming the variable. When the policy does not allow it, sudo may refuse the whole command with an error. Plain `sudo` without the option drops the variable, and the join then stops with "there is no Tailscale auth key". The installer takes both variables out of its own environment as the first thing it does and hands the key only to the join step, so no other step, before or after the join, and no run where the join is skipped, starts a child process that inherits it. What it cannot do is scrub the block of the environment a process was started with: root can read that in `/proc/<process number>/environ` while the process runs, for the installer and for the two short-lived processes it hands the key to. A few short helper commands (such as uname, dirname, mktemp, mkdir, rm) run before main() on some runs and inherit the caller's environment; give the key through the root-owned key file to avoid this. Do not trace the installer (`bash -x`, or `set -x`) while a key is in your environment: the trace prints the key in plain text on the lines that hold it. The key is never put on a command line (tailscale reads it from a private temporary file), never written to the audit log, the install record, or any other file, and blanked out of anything tailscale prints.

What the join runs: `tailscale up --auth-key=file:<private copy> --advertise-tags=tag:agent --hostname=agent-<this machine's name> --ssh=false --accept-dns=false --accept-routes=false --reset --timeout=60s`. Tailscale SSH stays off (no level grants it), no exit node is used, and no routes or name resolution settings are accepted. It then records the node it joined (node number, host name, tag, never the key) in `/var/lib/sirven/tailscale-node.json`, root only.

Refused before any change, with what to do (the installer makes all of these checks before its first step): no key; a saved key file that is not a plain file owned by root with no permission for anyone else and no extended access control list (the mode bits alone cannot show one: on Linux a mask of `---` hides an entry for another account from them, so the check looks for the list itself); a key with characters no key has (a carriage return from Windows line ends, say); tailscale not installed (the message names the download page and the Debian package repository); tailscaled not answering; a tailscale too old to read a key from a file. A second apply finds the node already logged in with `tag:agent` and does nothing, and needs no key. A machine already logged in without `tag:agent` is refused, never re-tagged.

Undo, by `install.sh revoke --all` and by `uninstall.sh` (the install record carries the same undo): `tailscale logout`, and only when this machine's login is still the exact node the record names and it still has `tag:agent`. A login someone else made, or any other node of your tailnet, is never touched; the stale record is dropped and the run says so. With an ephemeral key the node leaves the tailnet at once; with any other key the machine entry stays listed (expired) in the admin console until you delete it, and the revoke plan says so. If tailscaled does not answer, the logout fails loudly, the record stays, and the run can be repeated. If tailscale is gone, there is nothing to log out and the record is dropped. Revoke then uninstall works: uninstall finds the record already gone. A join that logs in but does not reach Running (a tagged key that is not pre-approved ends in `NeedsMachineAuth`) fails the install and leaves the login and its record: `revoke --all` and `uninstall.sh` log that node out too, because they act on the record file whether or not the install record has a line for it. A copy of the key left by a join that was killed is removed by the next join, by the logout, and by uninstall.

Real macOS machines and Linux machines outside a container stay plan only for the install (the installer refuses to apply there); the kill switch logout runs on a real Linux machine like the rest of the kill switch.

Asking for a different level or path on purpose is not a conflict: the plan says the grant in force changes, and `sirven grant rollback` reverses it.


## The Cloudflare tunnel, and how it is undone

With `--transport cloudflare` a real apply on Linux makes one Cloudflare Tunnel for this machine and runs it as a service of its own. You give it a hostname in a zone of your own Cloudflare account that nothing uses yet (`--cloudflare-hostname agent.your-zone.example`, or `SIRVEN_CLOUDFLARE_HOSTNAME`), your account number (`--cloudflare-account`, or `SIRVEN_CLOUDFLARE_ACCOUNT_ID`), and one API token. Make the token in the Cloudflare dashboard (My Profile, API Tokens) with the permissions Account, Cloudflare Tunnel, Edit and Zone, domain name records, Edit, limited to your one account and the one zone (add Zone, Zone, Read unless you name the zone yourself in `SIRVEN_CLOUDFLARE_ZONE_ID`). Never give it a token that can do anything else: it is the only credential the installer holds, and it is a token for a tunnel and a record, nothing more.

Give the token one of two ways, and use the file first: save it as `/etc/sirven/cloudflare-api-token`, a plain file owned by root with mode 0600, one name only, and no extended access control list (the same checks as the Tailscale key file; a file that fails them is refused, not used), or set `SIRVEN_CLOUDFLARE_API_TOKEN` in the environment (through sudo that needs `sudo --preserve-env=SIRVEN_CLOUDFLARE_API_TOKEN`, which sudo allows only when its policy does). The installer takes the variable out of its own environment as the first thing it does and hands the token only to the steps that need it: the first look that checks it, the step that makes the tunnel, and the step that takes it away. It reaches the program that talks to the API through standard input only, never on a command line, and it is never written to the audit log, the install record or any other file. What it cannot do is scrub the block of the environment a process was started with: root can read it in `/proc/<process number>/environ` while the process runs, and a few short helper commands (such as uname, dirname, mktemp) run before main() on some runs and inherit the caller's environment; give the token through the root-owned file to avoid this. Do not trace the installer (`bash -x`) while a token is in your environment. The saved token file is removed after the tunnel is made, so you give the token again to take the tunnel away.

What apply does, in this order, writing each thing to a root-only record (`/var/lib/sirven/cloudflare-tunnel.json`, never the token) as soon as it exists: records a unique tunnel name first; makes a tunnel of that name in your account, managed from this machine (its routes are the config file on this machine, so the dashboard cannot widen them); keeps its credentials in `/etc/sirven/cloudflared-credentials.json` and its config in `/etc/sirven/cloudflared.yml`, both root-only; checks the config with cloudflared; points your hostname at the tunnel with an alias record; writes the unit `/etc/systemd/system/sirven-cloudflared.service` and starts it. The service runs as root, never as the agent account, and only dials out. It has a name of its own: sirven never runs `cloudflared service install`, never reads or writes `/etc/cloudflared`, and never touches a cloudflared you already run.

The config routes exactly one hostname to this machine's SSH server (`ssh://localhost:22`) and answers every other name with 404, whatever the level. There is no other port and no private network route. The owner step that stays by hand is Cloudflare Access: add the hostname as a self-hosted application whose policy allows only a service token for your agent client, and do it before you give the hostname to anyone; until then only the agent's SSH keys stand in the way.

Refused before any change, with what to do: no hostname or account; no token, or a saved token file that cannot be trusted; cloudflared missing or older than 2024.1.0 (with where to get it); no systemd; a token the API turns away; a zone that cannot be found; a hostname that already has a record in the zone that sirven did not make. A second apply needs no token and does nothing. A run that stops halfway (the record refused, the service would not start) leaves the record file naming what exists; apply again to finish it with the same tunnel, or take it away.

Undo, by `install.sh revoke --all` (whatever transport it names) and by `uninstall.sh` (also for a tunnel a failed run left and never wrote to the install record): the service is stopped and disabled, the unit, the config and the credentials are removed, then, in your account, the alias record is deleted only while it still points at this tunnel and the tunnel only while it still has the recorded name, so a record or tunnel you changed or made yourself is left alone. The part on this machine needs no token. The part in your account does: without the token the command still cuts this machine off, says plainly which tunnel and record are still in your account, keeps the record, and exits 4; run the same command again with the token and it finishes. Then delete the Access application and the API token you made, by hand.

Real macOS machines stay plan only; the tunnel service is a systemd unit.

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
