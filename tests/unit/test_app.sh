# shellcheck shell=bash
# the tier dial, consent moment, site list, and usage meter in app/: copy coverage, the
# fake interfaces, and the local server's limits.

# loads app/main.js into node with no page, so its plain functions can be called directly.
run_app_script() {
  if ! command -v node >/dev/null 2>&1; then
    echo "node not found, so this check was skipped"
    return 0
  fi
  REPO_DIR="$REPO_DIR" node --input-type=module -e "
    import { readFileSync } from 'node:fs';
    import vm from 'node:vm';
    const repo = process.env.REPO_DIR;
    const context = vm.createContext({ console, fetch: () => new Promise(() => {}), document: {}, location: { search: '' } });
    vm.runInContext(readFileSync(repo + '/app/main.js', 'utf8'), context);
    context.COPY_FOR_TESTS = () => vm.runInContext('COPY', context);
    const read = (path) => readFileSync(repo + '/' + path, 'utf8');
    context.parseCopy(read('copy/consent-moment.md'));
    context.parseCopy(read('copy/surfaces.md'));
    const fail = (message) => { console.error(message); process.exit(1); };
    $1
  "
}

test_every_copy_key_the_app_uses_exists() {
  run_app_script "
    const source = read('app/main.js') + read('app/index.html');
    const keys = new Set();
    for (const [, key] of source.matchAll(/(?:\\bt\(|data-copy(?:-label)?=)[\"'\`]([a-z][a-z0-9_.]*)[\"'\`]/g)) keys.add(key);
    // keys built from a tier, an axis, a direction, or a scope, expanded over every value.
    const expand = { tier: ['solo', 'neighborly', 'coop'], preview: ['solo', 'neighborly', 'coop'], axis: ['lend', 'autonomy'] };
    for (const tier of expand.tier) { keys.add('dial.' + tier + '.name'); keys.add('dial.' + tier + '.summary');
      for (const axis of expand.axis) keys.add('dial.' + tier + '.' + axis); }
    for (const direction of ['carried', 'sent']) keys.add('meter.session.' + direction);
    for (const scope of ['read', 'authenticated']) keys.add('list.scope.' + scope);
    const missing = [...keys].filter((key) => !(key in context.COPY_FOR_TESTS()));
    if (missing.length) fail('missing copy keys: ' + missing.join(', '));
    if (keys.size < 60) fail('expected the scan to find the app copy keys, found ' + keys.size);
  "
}

test_copy_notes_never_reach_the_screen() {
  run_app_script "
    const copy = context.COPY_FOR_TESTS();
    for (const [key, text] of Object.entries(copy)) {
      if (!text) fail(key + ' has no text');
      if (/Note for Jose|^>/.test(text)) fail(key + ' carries a review note: ' + text);
    }
    if (copy['consent.block.title'] !== '{host} blocked your agent.') fail('consent.block.title parsed as ' + copy['consent.block.title']);
    if (context.t('consent.means.lend.body', { cap: '5 gigabytes' }) !== 'Up to 5 gigabytes a month of your connection, to other members\\' agents.') fail('placeholder fill failed');
  "
}

test_sizes_and_dates_read_as_plain_words() {
  run_app_script "
    const cases = [[5e9, '5 gigabytes'], [1e9, '1 gigabyte'], [1.856e9, '1.85 gigabytes'], [84e6, '84 megabytes'], [0, '0 kilobytes']];
    for (const [bytes, words] of cases) if (context.size(bytes) !== words) fail(bytes + ' read as ' + context.size(bytes));
    if (context.day('2026-11-01T00:00:00Z') !== 'November 1') fail('reset day read as ' + context.day('2026-11-01T00:00:00Z'));
    if (context.day('2026-10-02T00:00:00Z', true) !== 'October 2, 2026') fail('review day read as ' + context.day('2026-10-02T00:00:00Z', true));
  "
}

test_fake_interfaces_match_the_documented_shapes() {
  PYTHONDONTWRITEBYTECODE=1 REPO_DIR="$REPO_DIR" python3 - <<'PYTHON'
import json, os, pathlib, sys
fakes = pathlib.Path(os.environ["REPO_DIR"]) / "app" / "fakes"
def fail(message):
    print(message); sys.exit(1)
for path in (fakes / "runtime").glob("*.json"):
    state = json.loads(path.read_text())
    if set(state) != {"version", "tier", "peer_routing_available", "consent", "last_block"}: fail(f"{path.name}: fields {sorted(state)}")
    if state["tier"] not in ("solo", "neighborly", "coop"): fail(f"{path.name}: tier")
    block = state["last_block"]
    if block is not None and (block["outcome"] != "blocked" or not block["host"]): fail(f"{path.name}: block")
for path in (fakes / "ledger").glob("*.json"):
    ledger = json.loads(path.read_text())
    if ledger["cap_bytes"] != 5_000_000_000: fail(f"{path.name}: the cap is 5 gigabytes, symmetric")
    if ledger["used_bytes"] != ledger["carried_bytes"] + ledger["sent_bytes"]: fail(f"{path.name}: carried and sent must add up to used")
    if ledger["used_bytes"] > ledger["cap_bytes"]: fail(f"{path.name}: over the cap")
    for session in ledger["sessions"]:
        if session["direction"] not in ("carried", "sent"): fail(f"{path.name}: direction")
for path in (fakes / "registry").glob("*.json"):
    registry = json.loads(path.read_text())
    for entry in registry["entries"]:
        missing = {"domain", "status", "scope", "rationale", "last_reviewed_at", "next_review_by", "public_positions"} - set(entry)
        if missing: fail(f"{path.name}: {entry.get('domain')} lacks {sorted(missing)}")
        if not entry["domain"].endswith(".example") or not registry["test_data"]: fail(f"{path.name}: fake entries must be marked test data on reserved names")
PYTHON
}

# starts the server in this process on a free port and calls it like the page does.
server_check() {
  PYTHONDONTWRITEBYTECODE=1 REPO_DIR="$REPO_DIR" SCENARIO="$1" python3 - "$2" <<'PYTHON'
import json, os, sys, threading, urllib.request, urllib.error
sys.path.insert(0, os.path.join(os.environ["REPO_DIR"], "app"))
import serve
serve.Handler.fake = serve.Fake(os.environ["SCENARIO"], peer_preview=False, growth=0)
server = serve.ThreadingHTTPServer(("127.0.0.1", 0), serve.Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_address[1]}"
def call(path, body=None):
    request = urllib.request.Request(base + path, data=None if body is None else json.dumps(body).encode(), method="GET" if body is None else "POST")
    try:
        with urllib.request.urlopen(request) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()
def fail(message):
    print(message); sys.exit(1)
exec(sys.argv[1])
server.shutdown()
PYTHON
}

test_server_listens_on_loopback_only() {
  local hits
  hits="$(grep -n 'ThreadingHTTPServer((' "$REPO_DIR/app/serve.py")"
  assert_contains "$hits" '("127.0.0.1", args.port)'
}

test_server_serves_the_app_and_copy_and_nothing_else() {
  server_check first-block "
for path, want in [('/', 200), ('/copy/consent-moment.md', 200), ('/app/main.js', 200), ('/app/serve.py', 404),
                   ('/lib/common.sh', 404), ('/app/../lib/common.sh', 404), ('/app/%2e%2e/lib/common.sh', 404), ('/.git/config', 404)]:
    status, _ = call(path)
    if status != want: fail(f'{path}: {status}, wanted {want}')
"
}

test_neighborly_is_refused_until_peer_routing_is_open() {
  server_check first-block "
status, body = call('/api/tier', {'tier': 'neighborly'})
if status != 409 or json.loads(body)['error'] != 'peer_routing_unavailable': fail(f'neighborly: {status} {body}')
status, body = call('/api/tier', {'tier': 'coop'})
if status != 409 or json.loads(body)['error'] != 'tier_not_open': fail(f'coop: {status} {body}')
status, body = call('/api/state')
if json.loads(body)['tier'] != 'solo': fail('the tier moved')
"
}

test_consent_is_recorded_once_and_solo_is_always_reachable() {
  server_check neighborly "
status, body = call('/api/consent', {'decision': 'not_open'})
if status != 200 or not json.loads(body)['consent']['prompted']: fail(f'consent: {status} {body}')
status, body = call('/api/consent', {'decision': 'maybe'})
if status != 400: fail(f'unknown decision accepted: {status}')
status, body = call('/api/tier', {'tier': 'solo'})
if status != 200 or json.loads(body)['tier'] != 'solo': fail(f'solo: {status} {body}')
"
}

test_meter_stops_at_the_cap() {
  PYTHONDONTWRITEBYTECODE=1 REPO_DIR="$REPO_DIR" python3 - <<'PYTHON'
import os, sys, time
sys.path.insert(0, os.path.join(os.environ["REPO_DIR"], "app"))
import serve
fake = serve.Fake("near-cap", peer_preview=False, growth=10**12)
time.sleep(0.01)
ledger = fake.usage()
if ledger["used_bytes"] != ledger["cap_bytes"] or ledger["state"] != "over":
    print(ledger["used_bytes"], ledger["state"]); sys.exit(1)
if ledger["used_bytes"] != ledger["carried_bytes"] + ledger["sent_bytes"]:
    print("carried and sent no longer add up"); sys.exit(1)
PYTHON
}

# the live adapters in app/serve.py answer in the shapes of app/fakes: tests/app.
test_live_adapters_match_the_fake_shapes() {
  command -v python3 >/dev/null 2>&1 || return 0
  capture python3 -m unittest discover -s "$REPO_DIR/tests/app"
  assert_eq 0 "$CAPTURED_STATUS" "live adapter shape tests failed:
$CAPTURED_STDERR"
}
