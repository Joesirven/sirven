#!/usr/bin/env node
// the attestation command: the three roles, each keeping its own files in its own directory.
//
//   identity issuer   vouches for users. holds the issuer key, the certificates it issued, and
//                     the revocation list it publishes.
//   originator        the user's own device. holds the user's signing key, which never leaves
//                     it, the certificate for that key, and the bytes sent this period.
//   peer              the device asked to carry a request. holds the issuers it trusts, its
//                     allowlist, the newest revocation list, its ledger, the nonces it accepted,
//                     every envelope it carried, and an audit log of every verification.
//
// usage:
//   cli.mjs issuer init --dir DIR
//   cli.mjs issuer certify --dir DIR --request FILE [--days N]
//   cli.mjs issuer revoke --dir DIR (--user HANDLE | --key KEY) [--reason TEXT]
//   cli.mjs issuer publish --dir DIR [--valid-hours N]
//   cli.mjs user init --dir DIR --user HANDLE
//   cli.mjs user install-certificate --dir DIR --certificate FILE
//   cli.mjs sign --dir DIR --audience PEER --domain DOMAIN --bytes N [--lifetime SECONDS] [--request-digest HEX]
//   cli.mjs peer init --dir DIR --issuer-public-key FILE --allowlist FILE [--cap-bytes N]
//   cli.mjs peer install-revocation-list --dir DIR --list FILE
//   cli.mjs peer verify --dir DIR --host HOST --bytes N [--envelope FILE] [--request-digest HEX] [--allowlist FILE]
//   cli.mjs registry sign --dir ISSUER_DIR --registry FILE [--valid-hours N]
//   cli.mjs registry verify --dir PEER_DIR --signed FILE
//   cli.mjs trace --dir PEER_DIR [--envelope FILE]
//
// PEER is the identifier peer init prints and writes to DIR/peer-identifier: an envelope is
// good at that one peer only. standard input stands in for any FILE given as -, and for the envelope when --envelope is
// left out. SIRVEN_ATTESTATION_NOW (seconds since the epoch) fixes the clock for tests.
//
// exit status: 0 done or accepted, 3 refused, 64 usage error, 1 any other error.

import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';
import { LockUnavailable, withVerifyLock } from './verify-lock.mjs';
import {
  AttestationError,
  DEFAULT_CAP_BYTES,
  DEFAULT_REQUEST_LIFETIME_SECONDS,
  generateSigningKey,
  issueCertificate,
  issueRevocationList,
  keyIdentifier,
  makeCertificationRequest,
  newPeerIdentifier,
  openCertificationRequest,
  normalizeDomain,
  nowSeconds,
  openCertificate,
  openRegistry,
  openRevocationList,
  periodOf,
  privateKeyFromPem,
  privateKeyToPem,
  publicKeyFromText,
  publicKeyText,
  signRegistry,
  signRequest,
  traceEnvelope,
  trustedIssuerMap,
  validAudience,
  validUserHandle,
  verifyRequest,
} from './attestation.mjs';

const EXIT_REFUSED = 3;
const EXIT_USAGE = 64;

class UsageError extends Error {}

// files ---------------------------------------------------------------------------------------

function ensureDirectory(dir) {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(dir, 0o700);
}

// writeFileAtomic: a temporary file next to the target, then a rename, so a reader never sees
// half a file.
function writeFileAtomic(path, text, mode = 0o600) {
  const temporary = `${path}.${process.pid}.tmp`;
  writeFileSync(temporary, text, { mode });
  chmodSync(temporary, mode);
  renameSync(temporary, path);
}

function writeJson(path, value) {
  writeFileAtomic(path, `${JSON.stringify(value, null, 2)}\n`);
}

// test only: SIRVEN_ATTESTATION_TEST_HOLD_MS keeps a verify inside its locked step for that many
// milliseconds, after it has read the state. the verify.paused marker tells a test it is there.
function pauseForTests(dir) {
  const milliseconds = Number(process.env.SIRVEN_ATTESTATION_TEST_HOLD_MS || 0);
  if (!(milliseconds > 0)) return;
  writeFileSync(join(dir, 'verify.paused'), '');
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

function readJson(path, fallback) {
  if (fallback !== undefined && !existsSync(path)) return fallback;
  return JSON.parse(readFileSync(path, 'utf8'));
}

function readInput(path) {
  return readFileSync(path === undefined || path === '-' ? 0 : path, 'utf8');
}

// a private key is written once, never overwritten, readable by its owner only.
function writePrivateKey(path, privateKey) {
  if (existsSync(path)) throw new UsageError(`${path} already exists; a signing key is never overwritten`);
  writeFileSync(path, privateKeyToPem(privateKey), { mode: 0o600, flag: 'wx' });
  chmodSync(path, 0o600);
}

function readPrivateKey(path) {
  if (!existsSync(path)) throw new UsageError(`no signing key at ${path}; run init first`);
  const mode = statSync(path).mode & 0o777;
  if (mode & 0o077) throw new Error(`${path} is readable by others (mode ${mode.toString(8)}); run chmod 600 on it`);
  return privateKeyFromPem(readFileSync(path, 'utf8'));
}

function printJson(value) {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

// arguments -----------------------------------------------------------------------------------

function parseOptions(argv, allowed) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (!flag.startsWith('--')) throw new UsageError(`unexpected argument: ${flag}`);
    const name = flag.slice(2);
    if (!allowed.includes(name)) throw new UsageError(`unknown option: ${flag}`);
    const value = argv[index + 1];
    if (value === undefined) throw new UsageError(`${flag} needs a value`);
    options[name] = value;
    index += 1;
  }
  return options;
}

function required(options, name) {
  if (options[name] === undefined || options[name] === '') throw new UsageError(`--${name} is required`);
  return options[name];
}

function wholeNumber(text, name) {
  if (!/^[0-9]+$/.test(String(text))) throw new UsageError(`--${name} must be a whole number`);
  const value = Number(text);
  if (!Number.isSafeInteger(value)) throw new UsageError(`--${name} is too large`);
  return value;
}

// identity issuer -----------------------------------------------------------------------------

function issuerInit(options) {
  const dir = required(options, 'dir');
  ensureDirectory(dir);
  const { privateKey } = generateSigningKey();
  writePrivateKey(join(dir, 'issuer.key'), privateKey);
  writeFileAtomic(join(dir, 'issuer.pub'), `${publicKeyText(privateKey)}\n`, 0o644);
  writeJson(join(dir, 'revocations.json'), { sequence: 0, users: [], keys: [] });
  writeFileAtomic(join(dir, 'issued.jsonl'), '');
  printJson({ issuer: keyIdentifier(privateKey), public_key: publicKeyText(privateKey) });
}

function issuerCertify(options) {
  const dir = required(options, 'dir');
  const days = wholeNumber(options.days ?? '365', 'days');
  // the request is signed by the key it asks to certify: proof the asker holds that key.
  const request = openCertificationRequest(JSON.parse(readInput(required(options, 'request'))));
  const issuerPrivateKey = readPrivateKey(join(dir, 'issuer.key'));
  // one key, one person: a key already certified for someone else is never certified again.
  const issued = readFileSync(join(dir, 'issued.jsonl'), 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const holder = issued.find((entry) => entry.key === request.key && entry.user !== request.user);
  if (holder) throw new Error(`key ${request.key} is already certified for another user`);
  const now = nowSeconds();
  const certificate = issueCertificate({ issuerPrivateKey, user: request.user, userPublicKey: request.public_key, issuedAt: now, expiresAt: now + days * 86400 });
  const payload = openCertificate(certificate, trustedIssuerMap([issuerPrivateKey]), now);
  // the issuer's half of traceability: which serial and key it issued to which user, and when.
  appendFileSync(join(dir, 'issued.jsonl'), `${JSON.stringify({ serial: payload.serial, user: payload.user, key: payload.key, issued_at: payload.issued_at, expires_at: payload.expires_at })}\n`, { mode: 0o600 });
  printJson(certificate);
}

function issuerRevoke(options) {
  const dir = required(options, 'dir');
  if ((options.user === undefined) === (options.key === undefined)) throw new UsageError('give exactly one of --user or --key');
  const state = readJson(join(dir, 'revocations.json'));
  const entry = { revoked_at: nowSeconds(), reason: options.reason || '' };
  if (options.user !== undefined) {
    if (!validUserHandle(options.user)) throw new UsageError(`not a valid user handle: ${options.user}`);
    if (!state.users.some((item) => item.user === options.user)) state.users.push({ user: options.user, ...entry });
  } else if (!state.keys.some((item) => item.key === options.key)) {
    state.keys.push({ key: options.key, ...entry });
  }
  writeJson(join(dir, 'revocations.json'), state);
  printJson({ revoked: options.user !== undefined ? { user: options.user } : { key: options.key }, note: 'run issuer publish to give peers the new list' });
}

function issuerPublish(options) {
  const dir = required(options, 'dir');
  const hours = wholeNumber(options['valid-hours'] ?? '24', 'valid-hours');
  if (hours < 1) throw new UsageError('--valid-hours must be at least 1');
  const issuerPrivateKey = readPrivateKey(join(dir, 'issuer.key'));
  const state = readJson(join(dir, 'revocations.json'));
  state.sequence += 1;
  const now = nowSeconds();
  const list = issueRevocationList({ issuerPrivateKey, sequence: state.sequence, issuedAt: now, nextUpdate: now + hours * 3600, users: state.users, keys: state.keys });
  writeJson(join(dir, 'revocations.json'), state);
  writeJson(join(dir, 'revocation-list.json'), list);
  printJson(list);
}

// originator ----------------------------------------------------------------------------------

function userInit(options) {
  const dir = required(options, 'dir');
  const user = required(options, 'user');
  if (!validUserHandle(user)) throw new UsageError(`not a valid user handle: ${user}; use lowercase letters, digits, dot, dash, underscore`);
  ensureDirectory(dir);
  const { privateKey } = generateSigningKey();
  writePrivateKey(join(dir, 'signing.key'), privateKey);
  writeFileAtomic(join(dir, 'user'), `${user}\n`);
  // the certification request holds the public key only, signed with the private key. it is what
  // goes to the issuer.
  const request = makeCertificationRequest({ userPrivateKey: privateKey, user, now: nowSeconds() });
  writeJson(join(dir, 'certification-request.json'), request);
  printJson(request);
}

function userInstallCertificate(options) {
  const dir = required(options, 'dir');
  const certificate = JSON.parse(readInput(required(options, 'certificate')));
  const privateKey = readPrivateKey(join(dir, 'signing.key'));
  const payload = JSON.parse(Buffer.from(certificate.payload, 'base64url').toString('utf8'));
  if (payload.key !== keyIdentifier(privateKey)) throw new Error('this certificate is for a different key than the one on this device');
  writeJson(join(dir, 'certificate.json'), certificate);
  printJson({ installed: true, user: payload.user, key: payload.key, expires_at: payload.expires_at });
}

function signCommand(options) {
  const dir = required(options, 'dir');
  const domain = required(options, 'domain');
  const audience = required(options, 'audience');
  if (!validAudience(audience)) throw new UsageError('--audience must be the identifier the peer printed at peer init');
  const requestBytes = wholeNumber(required(options, 'bytes'), 'bytes');
  const lifetime = wholeNumber(options.lifetime ?? String(DEFAULT_REQUEST_LIFETIME_SECONDS), 'lifetime');
  const userPrivateKey = readPrivateKey(join(dir, 'signing.key'));
  const certificatePath = join(dir, 'certificate.json');
  if (!existsSync(certificatePath)) throw new UsageError('no certificate installed; run user install-certificate first');
  const certificate = readJson(certificatePath);
  const now = nowSeconds();
  const period = periodOf(now);
  const usage = readJson(join(dir, 'usage.json'), {});
  const usedBytes = usage[period] || 0;
  const requestDigest = options['request-digest'];
  const envelope = signRequest({ userPrivateKey, certificate, audience, domain, requestBytes, usedBytes, now, lifetime, requestDigest });
  // sending counts against the cap the moment an envelope is signed.
  usage[period] = usedBytes + requestBytes;
  writeJson(join(dir, 'usage.json'), usage);
  printJson(envelope);
}

// peer ----------------------------------------------------------------------------------------

function loadTrustedIssuers(dir) {
  return trustedIssuerMap(readJson(join(dir, 'trusted-issuers.json')));
}

function peerInit(options) {
  const dir = required(options, 'dir');
  const issuerKey = readInput(required(options, 'issuer-public-key')).trim();
  publicKeyFromText(issuerKey);
  const domains = readInput(required(options, 'allowlist'))
    .split('\n')
    .map((line) => line.replace(/#.*/, '').trim())
    .filter((line) => line.length > 0);
  const allowlist = domains.map((domain) => {
    const normalized = normalizeDomain(domain);
    if (!normalized) throw new UsageError(`allowlist entry is not a plain domain name: ${domain}`);
    return normalized;
  });
  const capBytes = wholeNumber(options['cap-bytes'] ?? String(DEFAULT_CAP_BYTES), 'cap-bytes');
  ensureDirectory(dir);
  ensureDirectory(join(dir, 'carried'));
  writeJson(join(dir, 'trusted-issuers.json'), [issuerKey]);
  const peer = newPeerIdentifier();
  writeJson(join(dir, 'policy.json'), { peer, allowlist: [...new Set(allowlist)].sort(), cap_bytes: capBytes });
  writeFileAtomic(join(dir, 'peer-identifier'), `${peer}\n`, 0o644);
  writeJson(join(dir, 'ledger.json'), {});
  writeJson(join(dir, 'nonces.json'), {});
  printJson({ peer, trusted_issuer: keyIdentifier(issuerKey), allowlist: [...new Set(allowlist)].sort(), cap_bytes: capBytes });
}

function peerInstallRevocationList(options) {
  const dir = required(options, 'dir');
  const list = JSON.parse(readInput(required(options, 'list')));
  const path = join(dir, 'revocation-list.json');
  const previousSequence = existsSync(path) ? readJson(path).sequence_seen || 0 : 0;
  const opened = openRevocationList(list, loadTrustedIssuers(dir), { previousSequence });
  writeJson(path, { sequence_seen: opened.sequence, list });
  printJson({ installed: true, sequence: opened.sequence, next_update: opened.next_update, revoked_users: opened.users.length, revoked_keys: opened.keys.length });
}

function peerVerify(options) {
  const dir = required(options, 'dir');
  const host = required(options, 'host');
  const requestBytes = wholeNumber(required(options, 'bytes'), 'bytes');
  const text = readInput(options.envelope);
  let now = nowSeconds();
  const trustedIssuers = loadTrustedIssuers(dir);
  const policy = readJson(join(dir, 'policy.json'));
  // --allowlist: the domains of the registry version the node verified, one per line. it
  // replaces the list written at peer init, so the published registry is the one source.
  const allowlist = options.allowlist === undefined
    ? policy.allowlist
    : readInput(options.allowlist).split('\n').map((line) => line.trim()).filter(Boolean).map((domain) => normalizeDomain(domain)).filter(Boolean);
  let verdict;
  // the nonce memory and the ledger are read, checked and written back as one step. without the
  // lock, two verifies of one envelope could both read before either writes and both be accepted.
  // a verify that cannot take the lock is refused, never run without it.
  try {
    withVerifyLock(join(dir, 'verify.lock'), () => {
      now = nowSeconds(); // read under the lock: the wait for it can be long
      const ledger = readJson(join(dir, 'ledger.json'), {});
      const nonces = readJson(join(dir, 'nonces.json'), {});
      // forget nonces whose envelopes have expired: an expired envelope is refused anyway.
      for (const [nonce, expiresAt] of Object.entries(nonces)) if (expiresAt <= now) delete nonces[nonce];
      pauseForTests(dir);

      let revocationList = null;
      const listPath = join(dir, 'revocation-list.json');
      try {
        if (existsSync(listPath)) {
          const stored = readJson(listPath);
          revocationList = openRevocationList(stored.list, trustedIssuers, { previousSequence: stored.sequence_seen });
        }
      } catch (error) {
        if (!(error instanceof AttestationError)) throw error;
        revocationList = null;
      }
      verdict = verifyRequest(text, {
        trustedIssuers,
        revocationList,
        audience: policy.peer,
        allowlist: new Set(allowlist),
        host,
        requestDigest: options['request-digest'],
        requestBytes,
        now,
        capBytes: policy.cap_bytes,
        carriedBytes: (user, period) => (ledger[user] && ledger[user][period]) || 0,
        seenNonce: (nonce) => Object.prototype.hasOwnProperty.call(nonces, nonce),
      });

      if (verdict.accepted) {
        // the order of these writes decides what a crash between them does. the nonce is remembered
        // first, so the envelope is spent before anything else happens: a crash after this point
        // refuses the envelope as replayed. the bytes are charged last. a crash can then leave one
        // request uncharged, which is the lesser loss. the other order would charge bytes whose
        // envelope could be spent again.
        nonces[verdict.nonce] = verdict.expires_at;
        writeJson(join(dir, 'nonces.json'), nonces);
        // keep the envelope: it is the evidence an abuse report is traced from.
        ensureDirectory(join(dir, 'carried'));
        writeFileAtomic(join(dir, 'carried', `${verdict.nonce}.json`), text.endsWith('\n') ? text : `${text}\n`);
        ledger[verdict.user] = ledger[verdict.user] || {};
        ledger[verdict.user][verdict.period] = (ledger[verdict.user][verdict.period] || 0) + requestBytes;
        writeJson(join(dir, 'ledger.json'), ledger);
      }
    });
  } catch (error) {
    if (!(error instanceof LockUnavailable)) throw error;
    verdict = { accepted: false, reason: 'lock_unavailable', detail: 'another peer verify holds the lock, so this request was not run' };
  }
  const entry = verdict.accepted
    ? { time: new Date(now * 1000).toISOString().replace(/\.000Z$/, 'Z'), event: 'attestation_verify', outcome: 'accepted', user: verdict.user, key: verdict.key, certificate_serial: verdict.certificate_serial, domain: verdict.domain, host, bytes: requestBytes, period: verdict.period, nonce: verdict.nonce }
    : { time: new Date(now * 1000).toISOString().replace(/\.000Z$/, 'Z'), event: 'attestation_verify', outcome: 'refused', reason: verdict.reason, detail: verdict.detail, host, bytes: requestBytes };
  appendFileSync(join(dir, 'audit.jsonl'), `${JSON.stringify(entry)}\n`, { mode: 0o600 });
  printJson(verdict);
  return verdict.accepted ? 0 : EXIT_REFUSED;
}

// registry ------------------------------------------------------------------------------------

function registrySign(options) {
  const dir = required(options, 'dir');
  const hours = wholeNumber(options['valid-hours'] ?? '168', 'valid-hours');
  if (hours < 1) throw new UsageError('--valid-hours must be at least 1');
  const issuerPrivateKey = readPrivateKey(join(dir, 'issuer.key'));
  const registryBytes = readFileSync(required(options, 'registry'));
  const now = nowSeconds();
  printJson(signRegistry({ issuerPrivateKey, registryBytes, publishedAt: now, expiresAt: now + hours * 3600 }));
}

// registry verify: prints {issuer, registry_sha256, published_at, expires_at, registry} where
// registry is the parsed registry. exit status 3 when the signature or issuer is refused.
function registryVerify(options) {
  const dir = required(options, 'dir');
  const opened = openRegistry(JSON.parse(readInput(required(options, 'signed'))), loadTrustedIssuers(dir));
  printJson({ issuer: opened.issuer, registry_sha256: opened.registry_sha256, published_at: opened.published_at, expires_at: opened.expires_at, registry: JSON.parse(opened.registry_bytes.toString('utf8')) });
}

function traceCommand(options) {
  const dir = required(options, 'dir');
  printJson(traceEnvelope(readInput(options.envelope), loadTrustedIssuers(dir)));
}

// main ----------------------------------------------------------------------------------------

const COMMANDS = {
  'issuer init': [issuerInit, ['dir']],
  'issuer certify': [issuerCertify, ['dir', 'request', 'days']],
  'issuer revoke': [issuerRevoke, ['dir', 'user', 'key', 'reason']],
  'issuer publish': [issuerPublish, ['dir', 'valid-hours']],
  'user init': [userInit, ['dir', 'user']],
  'user install-certificate': [userInstallCertificate, ['dir', 'certificate']],
  'peer init': [peerInit, ['dir', 'issuer-public-key', 'allowlist', 'cap-bytes']],
  'peer install-revocation-list': [peerInstallRevocationList, ['dir', 'list']],
  'peer verify': [peerVerify, ['dir', 'host', 'bytes', 'envelope', 'request-digest', 'allowlist']],
  'registry sign': [registrySign, ['dir', 'registry', 'valid-hours']],
  'registry verify': [registryVerify, ['dir', 'signed']],
  sign: [signCommand, ['dir', 'audience', 'domain', 'bytes', 'lifetime', 'request-digest']],
  trace: [traceCommand, ['dir', 'envelope']],
};

function usage() {
  return `usage:
  cli.mjs issuer init --dir DIR
  cli.mjs issuer certify --dir DIR --request FILE [--days N]
  cli.mjs issuer revoke --dir DIR (--user HANDLE | --key KEY) [--reason TEXT]
  cli.mjs issuer publish --dir DIR [--valid-hours N]
  cli.mjs user init --dir DIR --user HANDLE
  cli.mjs user install-certificate --dir DIR --certificate FILE
  cli.mjs sign --dir DIR --audience PEER --domain DOMAIN --bytes N [--lifetime SECONDS] [--request-digest HEX]
  cli.mjs peer init --dir DIR --issuer-public-key FILE --allowlist FILE [--cap-bytes N]
  cli.mjs peer install-revocation-list --dir DIR --list FILE
  cli.mjs peer verify --dir DIR --host HOST --bytes N [--envelope FILE] [--request-digest HEX] [--allowlist FILE]
  cli.mjs registry sign --dir ISSUER_DIR --registry FILE [--valid-hours N]
  cli.mjs registry verify --dir PEER_DIR --signed FILE
  cli.mjs trace --dir PEER_DIR [--envelope FILE]

exit status: 0 done or accepted, 3 refused, 64 usage error, 1 any other error.
`;
}

function main(argv) {
  if (argv.length === 0 || argv[0] === '--help' || argv[0] === 'help') {
    process.stdout.write(usage());
    return argv.length === 0 ? EXIT_USAGE : 0;
  }
  const two = `${argv[0]} ${argv[1]}`;
  const [name, rest] = COMMANDS[two] ? [two, argv.slice(2)] : [argv[0], argv.slice(1)];
  const command = COMMANDS[name];
  try {
    if (!command) throw new UsageError(`unknown command: ${argv.slice(0, 2).join(' ')}`);
    const [handler, allowed] = command;
    return handler(parseOptions(rest, allowed)) || 0;
  } catch (error) {
    if (error instanceof UsageError) {
      process.stderr.write(`error: ${error.message}\nrun cli.mjs --help for usage.\n`);
      return EXIT_USAGE;
    }
    if (error instanceof AttestationError) {
      process.stderr.write(`refused: ${error.message}\n`);
      return EXIT_REFUSED;
    }
    process.stderr.write(`error: ${error.message}\n`);
    return 1;
  }
}

process.exitCode = main(process.argv.slice(2));
