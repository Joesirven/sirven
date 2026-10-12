# optional components

sirven's core is the access levels: the service user, the grants, the audit log, the kill
switch. A component is something sirven can set up next to that for you, but never needs. Core
installs, grants, revokes, and uninstalls the same whether or not you add one, and a test proves
it (`test_core_works_with_no_components_folder` in `tests/unit/test_components.sh`).

Components work like shadcn: `sirven add` copies the component's files into a folder you own,
where they are yours to read and edit. There is no hidden dependency to update behind your back,
and running `sirven add` again never overwrites a file that is already there.

```
sirven add --list                 the components, and which ones are added
sirven add crm --dry-run          print the plan for the customer relationship component
sirven add crm                    print the same plan, then apply it
sirven remove crm --dry-run       print the removal plan
```

`add` and `remove` use the installer's plan engine (`lib/plan.sh`). Every step has a check of its
end state, a step that is already done shows as already done and is skipped, `--dry-run` changes
nothing, and applying writes every step to the installer's audit log, with the operation
`add crm` or `remove crm`. Applying follows the same rule as `install.sh` in the alpha cut: a fake
root with `--prefix`, or a throwaway linux container as root. Applying also needs the audit log,
so install sirven first.

Components are never written to the install record, so `./uninstall.sh` leaves them alone. Remove
one with `sirven remove NAME` first.

## where things go

- The folder: `~/.config/sirven/components/NAME` (or under `$XDG_CONFIG_HOME` when set). Choose
  another with `--dir PATH`.
- Credentials: a dotenv you control. By default `.env` inside the folder, mode 0600. Name another
  with `--env-file PATH`, for example a file that `bb secret` wrote, so the value never passes
  through an agent's transcript. A value already in the file is kept.
- Never the repository: `--dir` and `--env-file` are refused when they point inside this copy of
  sirven, so neither the copied files nor a secret can be committed with it.

## the registry

The registry is the `components` folder, one file per component: `components/NAME.sh`. Each file
defines four functions, described at the top of `lib/components.sh`: a one-line summary, a
preflight, the add plan, and the remove plan. Nothing outside `lib/components.sh` and the
`components` folder knows any component by name.

## crm: Twenty

`sirven add crm` sets up [Twenty](https://twenty.com), an open source customer relationship
manager, on this machine with Docker Compose.

### how Twenty says to self-host it

Twenty's own guide, read on 2026-10-11:
[Docker Compose](https://docs.twenty.com/developers/self-host/capabilities/docker-compose)
(the same page is at `twenty.com/developers/section/self-hosting/docker-compose`). The newest
release on Docker Hub that day was v2.46.0. The guide says:

- You need Docker and Docker Compose, installed and up to date, and at least 2 gigabytes of
  memory. Twenty's own install script refuses Docker Compose older than version 2.
- Option 1 is a one-line script piped from GitHub into bash. Option 2 is manual: copy
  `.env.example` to `.env`, set `ENCRYPTION_KEY` from `openssl rand -base64 32`, set
  `PG_DATABASE_PASSWORD` from `openssl rand -hex 32` (no special characters, because it goes
  into the Postgres connection address unencoded), download `docker-compose.yml`, then
  `docker compose up -d`, then open `http://localhost:3000`.
- "Losing `ENCRYPTION_KEY` means losing access to every secret stored in the database."
- Set `SERVER_URL` to the address people use. Put Twenty behind a reverse proxy with HTTPS when
  it is reached from anywhere but the machine itself.
- The files come from `packages/twenty-docker` in
  [github.com/twentyhq/twenty](https://github.com/twentyhq/twenty); for a given release, the
  script fetches them from the git tag `twenty/<version>`.

sirven follows option 2, one plan step per manual step, rather than piping a script into bash.

### what sirven add crm does

1. Creates the folder (mode 0700).
2. Copies a Docker Compose file, written from Twenty's own at release v2.46.0, with three
   changes: the Twenty image is pinned to v2.46.0, port 3000 answers on 127.0.0.1 only, and the
   two secrets have no defaults, so Docker Compose stops if the dotenv lacks them. Twenty's file
   publishes port 3000 on every network interface; sirven keeps it on this machine, so nobody
   else can reach a fresh Twenty before you have made its first workspace and chosen a transport.
3. Fills in the dotenv with `ENCRYPTION_KEY` and `PG_DATABASE_PASSWORD`, made on this machine
   with `openssl rand` as the guide says. The values are never printed, never in the plan, and
   never in the audit log. A value already there is kept.
4. Gives the folder and the dotenv to you, the owner.
5. Starts Twenty with `docker compose up -d`.
6. Waits until Twenty answers at `http://localhost:3000/healthz`, for up to 5 minutes: the first
   start sets up the database.
7. By hand: open `http://localhost:3000` and create the first workspace.
8. By hand, if your agent should use Twenty: create an API key in Twenty's settings for it, and
   keep it in a dotenv you control, for example with `bb secret`. Never in a repository.

### what sirven remove crm does

It stops the containers with `docker compose down` and removes the Docker Compose file, unless
you changed it, in which case it is kept and the plan says so. It keeps the Docker volumes (the
database and uploaded files) and the dotenv (which holds `ENCRYPTION_KEY`), because without them
the data is gone for good. `--remove-data` deletes both too. A dotenv you named with
`--env-file` is never removed.
