# SIR-31 finding: the per-session forced-command wrapper does not exist

Date: 2026-10-14. Base: origin/main 1cc13bb. Nothing was built, per the task rule: when the
wrapper is absent, write a precise finding and report.

## What was searched

A search of the whole repository (excluding `.git`) for `ForceCommand`, `command="` in an
authorized keys line, `forced command`, `session wrapper`, `per-session`, and `sshd`, then a read of
`lib/audit.sh`, `lib/service_user.sh`, `docs/PERMISSIONS.md`, `docs/SCOPE.md`.

## What exists

- `lib/audit.sh`: the log directory, the empty log, the format document (`audit-format.json`), and
  the writer used by the package's own commands (install, uninstall, grant, adopt, component,
  revoke). Those write `step`, `grant`, `adopt`, `install`, `uninstall`, `component`, `warning`,
  `revoke_*` and `reinstate` events only.
- `lib/service_user.sh:68` and `:177` create an empty `authorized_keys` file; `:195` tells the
  owner to append a bare public key. No key line carries a `command="..."` option, and no sshd
  configuration is written anywhere.
- The only sshd in the repository is the one the harness scenarios start themselves to test the
  kill switch (`tests/harness/scenarios/linux/30-revoke-live-session-and-key-login.sh:21-24`,
  `37-install-after-revoke-needs-reinstate.sh:41-42`). It is the package's default configuration.

## What does not exist

- No wrapper program, no `ForceCommand`, no `command=` restriction, no `restrict` or `no-pty`,
  `no-port-forwarding`, `no-agent-forwarding` option on the key, no `Subsystem` handling.
- No code anywhere writes the events `session_start`, `command` or `session_end`. They appear
  only in the format document: `lib/audit.sh:29` (event list), `:58` (example), and
  `lib/grant_compiler.py:156` (reads the two policy flags, enforces nothing about capture).
- Therefore the three things the task asked to verify (session start/command/end recorded, no
  bypass by another command, subsystem or port forwarding, valid JSON lines from the wrapper) have
  nothing to run against.

## What the documents claim, and where

Honest (say "not built"): `lib/audit.sh:79`, `bin/sirven:18`, `:244`, `:519`,
`docs/PERMISSIONS.md:74`, `docs/SCOPE.md:66` ("wrapper built if time allows") and `:106` (Alpha + 1),
`docs/status/2026-10-14-docs-claims.md` R16, W12.

Stated as fact without the caveat nearby (a reader can take these as built):

1. `docs/PERMISSIONS.md:40`: "sessions and commands are always logged; the agent can never read or
   write the log". The log part is a directory permission and is real; "always logged" is not
   true today. The claims file rates this P6 "TRUE as a level field", which is accurate about the
   field only.
2. `docs/PERMISSIONS.md:438`: friend invite adds a key "with a forced command that writes every
   command to the audit log". The section heading says "designed, not built", so this one is fine.
3. `docs/PERMISSIONS.md:489-490`: "audit capture is per session and per command through the
   forced-command wrapper." Present tense, no "not built". Suggest: "is designed to be".
4. `lib/audit.sh:5` and `:53`: the format document written to
   `<config>/audit-format.json` says "entries are appended by a forced-command wrapper on the SSH
   key". It is installed on the owner's machine as a rule of the format, with no "not built" note.
   The plan prints the note (`:79`) but the installed file does not carry it.
5. `docs/SCOPE.md:132-134` (risk 1) describes the wrapper's limit in present tense; the next
   sentence says audit is designed, not built, so this one is fine.

## Proposed ticket text

Build the per-session forced-command wrapper (SIR-31 W4 remainder): a key line option
`command="<wrapper>",restrict` (which disables forwarding, pty and agent forwarding) written by the
service user step; a wrapper that writes `session_start`, `command` (exactly as received in
`SSH_ORIGINAL_COMMAND`, JSON escaped through `audit_json_string`), `exit_status` and `session_end`
with a shared `session` token and `source` from `SSH_CONNECTION`, runs the command as the agent
and keeps the log owner-only; a harness scenario with a real sshd in the container (the image
already carries one) that proves: start, command and end are recorded; a different command,
`-s sftp` subsystem, `-L` port forward and `-N` do not bypass it; every line parses as JSON,
including a command holding quotes, a backslash, a newline and a tab. Decide first where the
wrapper reads its log path from, since the agent cannot read the owner's log directory (0750,
owner) and the wrapper runs as the agent: the wrapper needs a privileged append path (a small
setuid-free helper through `sudo -n` for one command, or a socket owned by the owner).

## Unverified

The design question in the last paragraph is open; it is the main reason this is not a trivial
build. Nothing about wrapper behaviour was run, because there is nothing to run.
