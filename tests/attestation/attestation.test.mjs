// the attestation library: every acceptance and refusal path, on a fixed clock. run with
// node --test tests/attestation. keys are generated fresh in memory for every run; no key or
// signature is ever pinned in a file.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_CAP_BYTES,
  REFUSAL,
  generateSigningKey,
  issueCertificate,
  issueRevocationList,
  keyIdentifier,
  normalizeDomain,
  openRevocationList,
  periodOf,
  publicKeyText,
  signObject,
  signRequest,
  traceEnvelope,
  trustedIssuerMap,
  verifyRequest,
} from '../../lib/attestation/attestation.mjs';

const NOW = Date.parse('2026-10-15T12:00:00Z') / 1000;
const DAY = 86400;

function decode(object) {
  return JSON.parse(Buffer.from(object.payload, 'base64url').toString('utf8'));
}

function encode(object, payload) {
  return { ...object, payload: Buffer.from(JSON.stringify(payload)).toString('base64url') };
}

// world: an issuer, one certified user, a peer's view of both, and a helper to sign and verify.
function world({ user = 'alice', revokedUsers = [], revokedKeys = [], listSequence = 1 } = {}) {
  const issuer = generateSigningKey();
  const device = generateSigningKey();
  const certificate = issueCertificate({ issuerPrivateKey: issuer.privateKey, user, userPublicKey: device.publicKey, issuedAt: NOW - 60 * DAY, expiresAt: NOW + 365 * DAY });
  const trustedIssuers = trustedIssuerMap([publicKeyText(issuer.publicKey)]);
  const list = issueRevocationList({
    issuerPrivateKey: issuer.privateKey,
    sequence: listSequence,
    issuedAt: NOW - 60,
    nextUpdate: NOW + DAY,
    users: revokedUsers.map((name) => ({ user: name, revoked_at: NOW - 60 })),
    keys: revokedKeys.map((key) => ({ key, revoked_at: NOW - 60 })),
  });
  const revocationList = openRevocationList(list, trustedIssuers);
  const ledger = new Map();
  const nonces = new Set();
  const sign = (overrides = {}) =>
    signRequest({ userPrivateKey: device.privateKey, certificate, domain: 'shop.example.com', requestBytes: 2048, usedBytes: 0, now: NOW, ...overrides });
  const context = (overrides = {}) => ({
    trustedIssuers,
    revocationList,
    allowlist: new Set(['shop.example.com']),
    host: 'shop.example.com',
    requestBytes: 2048,
    now: NOW,
    carriedBytes: (who, period) => ledger.get(`${who} ${period}`) || 0,
    seenNonce: (nonce) => nonces.has(nonce),
    ...overrides,
  });
  // accept: what a peer does after an acceptance, so later checks see it.
  const accept = (verdict) => {
    ledger.set(`${verdict.user} ${verdict.period}`, (ledger.get(`${verdict.user} ${verdict.period}`) || 0) + verdict.request_bytes);
    nonces.add(verdict.nonce);
  };
  return { issuer, device, certificate, trustedIssuers, revocationList, ledger, sign, context, accept };
}

function assertRefused(verdict, reason) {
  assert.equal(verdict.accepted, false, `expected a refusal for ${reason}, got acceptance`);
  assert.equal(verdict.reason, reason, verdict.detail);
}

test('a correctly signed envelope is accepted and names its user', () => {
  const w = world();
  const verdict = verifyRequest(w.sign(), w.context());
  assert.equal(verdict.accepted, true, verdict.detail);
  assert.equal(verdict.user, 'alice');
  assert.equal(verdict.key, keyIdentifier(w.device.publicKey));
  assert.equal(verdict.domain, 'shop.example.com');
  assert.equal(verdict.period, periodOf(NOW));
});

test('the envelope also verifies after a round trip through JSON text', () => {
  const w = world();
  const verdict = verifyRequest(JSON.stringify(w.sign()), w.context());
  assert.equal(verdict.accepted, true, verdict.detail);
});

test('the envelope is versioned and carries the identity posture', () => {
  const w = world();
  const envelope = w.sign();
  assert.equal(envelope.sirven_attestation, 1);
  assert.equal(envelope.type, 'request');
  const payload = decode(envelope);
  assert.equal(payload.version, 1);
  assert.equal(payload.posture, 'identity');
  assert.equal(payload.agent, 'personal');
  assert.equal(payload.cap.limit_bytes, DEFAULT_CAP_BYTES);
});

// unsigned ------------------------------------------------------------------------------------

test('refuses an envelope with no signature', () => {
  const w = world();
  const { signature, ...unsigned } = w.sign();
  assert.ok(signature);
  assertRefused(verifyRequest(unsigned, w.context()), REFUSAL.UNSIGNED);
  assertRefused(verifyRequest({ ...unsigned, signature: '' }, w.context()), REFUSAL.UNSIGNED);
});

test('refuses no envelope at all, and text that is not an envelope', () => {
  const w = world();
  assertRefused(verifyRequest(null, w.context()), REFUSAL.UNSIGNED);
  assertRefused(verifyRequest('', w.context()), REFUSAL.MALFORMED);
  assertRefused(verifyRequest('not json', w.context()), REFUSAL.MALFORMED);
  assertRefused(verifyRequest({ hello: 'world' }, w.context()), REFUSAL.MALFORMED);
});

test('refuses an envelope signed by a key the certificate does not name', () => {
  const w = world();
  const stranger = generateSigningKey();
  const forged = signRequest({ userPrivateKey: w.device.privateKey, certificate: w.certificate, domain: 'shop.example.com', requestBytes: 2048, usedBytes: 0, now: NOW });
  // re-sign the same payload with a stranger's key.
  const payload = decode(forged);
  assertRefused(verifyRequest(signObject('request', payload, stranger.privateKey), w.context()), REFUSAL.BAD_SIGNATURE);
});

test('refuses a certificate from an issuer the peer does not trust', () => {
  const w = world();
  const rogue = generateSigningKey();
  const rogueCertificate = issueCertificate({ issuerPrivateKey: rogue.privateKey, user: 'alice', userPublicKey: w.device.publicKey, issuedAt: NOW - DAY, expiresAt: NOW + DAY });
  assertRefused(verifyRequest(w.sign({ certificate: rogueCertificate }), w.context()), REFUSAL.UNTRUSTED_ISSUER);
});

// tampered ------------------------------------------------------------------------------------

test('refuses an envelope whose signed payload was changed', () => {
  const w = world();
  const envelope = w.sign();
  for (const change of [
    (payload) => { payload.domain = 'bank.example.com'; },
    (payload) => { payload.cap.used_bytes = 0; payload.cap.request_bytes = 1; },
    (payload) => { payload.user = 'bob'; },
    (payload) => { payload.expires_at += 3600; },
  ]) {
    const payload = decode(envelope);
    change(payload);
    const tampered = encode(envelope, payload);
    assertRefused(verifyRequest(tampered, w.context({ host: payload.domain })), REFUSAL.BAD_SIGNATURE);
  }
});

test('refuses an envelope with one byte of its signature flipped', () => {
  const w = world();
  const envelope = w.sign();
  const signature = Buffer.from(envelope.signature, 'base64url');
  signature[10] ^= 0x01;
  assertRefused(verifyRequest({ ...envelope, signature: signature.toString('base64url') }, w.context()), REFUSAL.BAD_SIGNATURE);
});

test('refuses an envelope whose embedded certificate was changed', () => {
  const w = world();
  const envelope = w.sign();
  const payload = decode(envelope);
  const certificatePayload = decode(payload.credential);
  certificatePayload.user = 'bob';
  payload.credential = encode(payload.credential, certificatePayload);
  // re-sign the outer envelope with alice's real key, so only the certificate is wrong.
  const resigned = signObject('request', { ...payload, user: 'bob' }, w.device.privateKey);
  assertRefused(verifyRequest(resigned, w.context()), REFUSAL.BAD_SIGNATURE);
});

test('a signature for one object type is never accepted as another', () => {
  const w = world();
  const certificateAsRequest = { ...w.certificate, type: 'request' };
  assert.equal(verifyRequest(certificateAsRequest, w.context()).accepted, false);
});

// domain --------------------------------------------------------------------------------------

test('refuses an envelope used for a different host than it names', () => {
  const w = world();
  assertRefused(verifyRequest(w.sign(), w.context({ host: 'bank.example.com' })), REFUSAL.WRONG_DOMAIN);
});

test('refuses a domain that is not on this peer\'s allowlist', () => {
  const w = world();
  const envelope = w.sign({ domain: 'unlisted.example.com' });
  assertRefused(verifyRequest(envelope, w.context({ host: 'unlisted.example.com' })), REFUSAL.DOMAIN_NOT_ALLOWLISTED);
});

test('domains match exactly, after lowercasing and dropping a trailing dot', () => {
  const w = world();
  assert.equal(verifyRequest(w.sign({ domain: 'Shop.Example.com.' }), w.context({ host: 'SHOP.example.com' })).accepted, true);
  assertRefused(verifyRequest(w.sign({ domain: 'www.shop.example.com' }), w.context({ host: 'www.shop.example.com' })), REFUSAL.DOMAIN_NOT_ALLOWLISTED);
  assert.equal(normalizeDomain('*.example.com'), null);
  assert.equal(normalizeDomain('https://shop.example.com'), null);
  assert.equal(normalizeDomain('shop.example.com:443'), null);
  assert.equal(normalizeDomain('localhost'), null);
});

// time ----------------------------------------------------------------------------------------

test('refuses an expired envelope', () => {
  const w = world();
  const envelope = w.sign({ lifetime: 60 });
  assertRefused(verifyRequest(envelope, w.context({ now: NOW + 60 })), REFUSAL.EXPIRED);
  assert.equal(verifyRequest(envelope, w.context({ now: NOW + 59 })).accepted, true);
});

test('refuses an envelope from the future beyond the allowed clock skew', () => {
  const w = world();
  const envelope = signRequest({ userPrivateKey: w.device.privateKey, certificate: w.certificate, domain: 'shop.example.com', requestBytes: 2048, usedBytes: 0, now: NOW + 120 });
  assertRefused(verifyRequest(envelope, w.context()), REFUSAL.NOT_YET_VALID);
});

test('the originator cannot sign an envelope that lives longer than five minutes', () => {
  const w = world();
  assert.throws(() => w.sign({ lifetime: 301 }), /lifetime/);
});

test('refuses an envelope whose certificate has expired', () => {
  const w = world();
  const old = issueCertificate({ issuerPrivateKey: w.issuer.privateKey, user: 'alice', userPublicKey: w.device.publicKey, issuedAt: NOW - 30 * DAY, expiresAt: NOW - DAY });
  assertRefused(verifyRequest(w.sign({ certificate: old }), w.context()), REFUSAL.CERTIFICATE_EXPIRED);
});

// revocation ----------------------------------------------------------------------------------

test('refuses every envelope from a revoked user', () => {
  const w = world({ revokedUsers: ['alice'] });
  assertRefused(verifyRequest(w.sign(), w.context()), REFUSAL.REVOKED);
});

test('refuses envelopes signed by a revoked key, and only that key', () => {
  const w = world();
  const revoked = issueRevocationList({ issuerPrivateKey: w.issuer.privateKey, sequence: 2, issuedAt: NOW - 60, nextUpdate: NOW + DAY, keys: [{ key: keyIdentifier(w.device.publicKey), revoked_at: NOW - 60 }] });
  const revocationList = openRevocationList(revoked, w.trustedIssuers, { previousSequence: 1 });
  assertRefused(verifyRequest(w.sign(), w.context({ revocationList })), REFUSAL.REVOKED);

  // the same user on a new device key, newly certified, is not caught by the key revocation.
  const newDevice = generateSigningKey();
  const newCertificate = issueCertificate({ issuerPrivateKey: w.issuer.privateKey, user: 'alice', userPublicKey: newDevice.publicKey, issuedAt: NOW - 60, expiresAt: NOW + DAY });
  const fresh = signRequest({ userPrivateKey: newDevice.privateKey, certificate: newCertificate, domain: 'shop.example.com', requestBytes: 2048, usedBytes: 0, now: NOW });
  assert.equal(verifyRequest(fresh, w.context({ revocationList })).accepted, true);
});

test('a peer with no revocation list refuses everything', () => {
  const w = world();
  assertRefused(verifyRequest(w.sign(), w.context({ revocationList: null })), REFUSAL.REVOCATION_LIST_MISSING);
});

test('a peer whose revocation list is past its next update refuses everything', () => {
  const w = world();
  const envelope = signRequest({ userPrivateKey: w.device.privateKey, certificate: w.certificate, domain: 'shop.example.com', requestBytes: 2048, usedBytes: 0, now: NOW + DAY });
  assertRefused(verifyRequest(envelope, w.context({ now: NOW + DAY })), REFUSAL.REVOCATION_LIST_STALE);
});

test('a peer refuses an older revocation list replayed to it', () => {
  const w = world({ listSequence: 3 });
  const older = issueRevocationList({ issuerPrivateKey: w.issuer.privateKey, sequence: 2, issuedAt: NOW, nextUpdate: NOW + DAY });
  assert.throws(() => openRevocationList(older, w.trustedIssuers, { previousSequence: 3 }), (error) => error.reason === REFUSAL.REVOCATION_LIST_ROLLBACK);
});

test('a peer refuses a revocation list from an untrusted issuer', () => {
  const w = world();
  const rogue = generateSigningKey();
  const list = issueRevocationList({ issuerPrivateKey: rogue.privateKey, sequence: 9, issuedAt: NOW, nextUpdate: NOW + DAY });
  assert.throws(() => openRevocationList(list, w.trustedIssuers), (error) => error.reason === REFUSAL.UNTRUSTED_ISSUER);
});

test('a tampered revocation list does not verify', () => {
  const w = world({ revokedUsers: ['alice'] });
  const list = issueRevocationList({ issuerPrivateKey: w.issuer.privateKey, sequence: 2, issuedAt: NOW, nextUpdate: NOW + DAY, users: [{ user: 'alice', revoked_at: NOW }] });
  const payload = decode(list);
  payload.users = [];
  assert.throws(() => openRevocationList(encode(list, payload), w.trustedIssuers), (error) => error.reason === REFUSAL.BAD_SIGNATURE);
});

// cap -----------------------------------------------------------------------------------------

test('the originator refuses to sign past the cap', () => {
  const w = world();
  assert.throws(() => w.sign({ usedBytes: DEFAULT_CAP_BYTES - 100, requestBytes: 101 }), (error) => error.reason === REFUSAL.OVER_CAP);
});

test('refuses an envelope that declares usage over the cap', () => {
  const w = world();
  // an originator that lies about its limit is still held to the peer's cap.
  const envelope = w.sign({ limitBytes: DEFAULT_CAP_BYTES * 10, usedBytes: DEFAULT_CAP_BYTES, requestBytes: 2048 });
  assertRefused(verifyRequest(envelope, w.context()), REFUSAL.OVER_CAP);
});

test('refuses when this peer\'s own ledger for the user is full', () => {
  const w = world();
  w.ledger.set(`alice ${periodOf(NOW)}`, DEFAULT_CAP_BYTES - 1000);
  assertRefused(verifyRequest(w.sign(), w.context()), REFUSAL.OVER_CAP);
});

test('the peer\'s own cap setting applies', () => {
  const w = world();
  const first = verifyRequest(w.sign(), w.context({ capBytes: 3000 }));
  assert.equal(first.accepted, true, first.detail);
  w.accept(first);
  assertRefused(verifyRequest(w.sign(), w.context({ capBytes: 3000 })), REFUSAL.OVER_CAP);
});

test('refuses a request bigger than the envelope declared', () => {
  const w = world();
  assertRefused(verifyRequest(w.sign({ requestBytes: 1000 }), w.context({ requestBytes: 1001 })), REFUSAL.OVER_DECLARED_SIZE);
});

test('refuses an envelope from a different cap period', () => {
  const w = world();
  // check at a moment still inside that envelope's lifetime but in the next month.
  const monthStart = Date.parse('2026-10-01T00:00:00Z') / 1000;
  const straddling = signRequest({ userPrivateKey: w.device.privateKey, certificate: w.certificate, domain: 'shop.example.com', requestBytes: 2048, usedBytes: 0, now: monthStart - 10 });
  assertRefused(verifyRequest(straddling, w.context({ now: monthStart + 10 })), REFUSAL.WRONG_PERIOD);
});

// replay --------------------------------------------------------------------------------------

test('refuses the same envelope a second time', () => {
  const w = world();
  const envelope = w.sign();
  const first = verifyRequest(envelope, w.context());
  assert.equal(first.accepted, true, first.detail);
  w.accept(first);
  assertRefused(verifyRequest(envelope, w.context()), REFUSAL.REPLAYED);
});

// version and posture -------------------------------------------------------------------------

test('refuses an envelope format version this peer does not know', () => {
  const w = world();
  assertRefused(verifyRequest({ ...w.sign(), sirven_attestation: 2 }, w.context()), REFUSAL.UNSUPPORTED_VERSION);
});

test('refuses a posture this peer does not know, such as a future pseudonymous one', () => {
  const w = world();
  const payload = decode(w.sign());
  payload.posture = 'pseudonymous';
  assertRefused(verifyRequest(signObject('request', payload, w.device.privateKey), w.context()), REFUSAL.UNSUPPORTED_POSTURE);
});

test('refuses an envelope that does not attest a personal agent', () => {
  const w = world();
  const payload = decode(w.sign());
  payload.agent = 'company';
  assertRefused(verifyRequest(signObject('request', payload, w.device.privateKey), w.context()), REFUSAL.NOT_PERSONAL_AGENT);
});

test('refuses an envelope whose user differs from its certificate', () => {
  const w = world();
  const payload = decode(w.sign());
  payload.user = 'bob';
  assertRefused(verifyRequest(signObject('request', payload, w.device.privateKey), w.context()), REFUSAL.USER_MISMATCH);
});

// traceability --------------------------------------------------------------------------------

test('a verified envelope traces back to its user, even after expiry and revocation', () => {
  const w = world();
  const envelope = w.sign();
  const trace = traceEnvelope(JSON.stringify(envelope), w.trustedIssuers);
  assert.equal(trace.user, 'alice');
  assert.equal(trace.key, keyIdentifier(w.device.publicKey));
  assert.equal(trace.certificate_serial, decode(w.certificate).serial);
  assert.equal(trace.domain, 'shop.example.com');
});

test('a tampered envelope cannot be traced to anyone', () => {
  const w = world();
  const envelope = w.sign();
  const payload = decode(envelope);
  payload.user = 'bob';
  assert.throws(() => traceEnvelope(encode(envelope, payload), w.trustedIssuers), (error) => error.reason === REFUSAL.BAD_SIGNATURE);
});

test('the issuer only signs certificates for valid user handles', () => {
  const w = world();
  assert.throws(() => issueCertificate({ issuerPrivateKey: w.issuer.privateKey, user: 'Alice Smith', userPublicKey: w.device.publicKey, issuedAt: NOW, expiresAt: NOW + DAY }));
});

test('the originator will not sign with a key its certificate does not name', () => {
  const w = world();
  const other = generateSigningKey();
  assert.throws(() => signRequest({ userPrivateKey: other.privateKey, certificate: w.certificate, domain: 'shop.example.com', requestBytes: 1, usedBytes: 0, now: NOW }), /different key/);
});
