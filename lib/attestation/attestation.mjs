// attestation: the signed envelope every peer-carried request travels with, and the checks a
// peer runs before it carries anything.
//
// three signed object types, each signed with Ed25519 through node's built-in crypto, so the
// package needs no library beyond node itself:
//
//   certification-request   the user's device asks the issuer to certify its public key, and
//                     proves it holds the private key by signing the request with it.
//   certificate       the identity issuer vouches that a public key belongs to a named user.
//   request           the user's own device key attests one request: a personal agent acting
//                     for that user, bounded to one domain, within the user's cap for the period.
//   revocation-list   the identity issuer lists users and keys peers must stop accepting.
//
// every signed object has the same outer shape:
//
//   {"sirven_attestation": 1, "type": "request", "payload": "<base64url>", "signature": "<base64url>"}
//
// the signature covers a context line ("sirven attestation <type> v<version>" and a newline)
// followed by the exact payload bytes. a verifier checks those bytes first and parses them
// second, so there is no JSON canonicalization to disagree about, and a signature made for one
// type can never be passed off as another.
//
// times are whole seconds since the epoch. byte counts are whole numbers.

import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, randomBytes, sign, verify } from 'node:crypto';

export const FORMAT_VERSION = 1;
export const SUPPORTED_VERSIONS = [1];
// identity is the first-shipped posture. a pseudonymous posture slots in later as a new posture
// value with its own credential type; a peer that does not know a posture refuses it.
export const POSTURE_IDENTITY = 'identity';
export const SUPPORTED_POSTURES = [POSTURE_IDENTITY];
export const AGENT_PERSONAL = 'personal';

// 5 gigabytes per person per month, carrying and sending counted the same. decimal gigabytes
// (5,000,000,000 bytes); a peer can configure a different number.
export const DEFAULT_CAP_BYTES = 5_000_000_000;
// a request envelope lives for minutes, not hours.
export const MAX_REQUEST_LIFETIME_SECONDS = 300;
export const DEFAULT_REQUEST_LIFETIME_SECONDS = 120;
export const CLOCK_SKEW_SECONDS = 30;

// every refusal reason a peer can give. stable strings: tests, audit entries, and the
// originator's error messages all use them.
export const REFUSAL = Object.freeze({
  MALFORMED: 'malformed',
  UNSIGNED: 'unsigned',
  UNSUPPORTED_VERSION: 'unsupported-version',
  UNSUPPORTED_POSTURE: 'unsupported-posture',
  BAD_SIGNATURE: 'bad-signature',
  UNTRUSTED_ISSUER: 'untrusted-issuer',
  CERTIFICATE_INVALID: 'certificate-invalid',
  CERTIFICATE_EXPIRED: 'certificate-expired',
  NOT_PERSONAL_AGENT: 'not-personal-agent',
  USER_MISMATCH: 'user-mismatch',
  EXPIRED: 'expired',
  NOT_YET_VALID: 'not-yet-valid',
  LIFETIME_TOO_LONG: 'lifetime-too-long',
  WRONG_AUDIENCE: 'wrong-audience',
  WRONG_DOMAIN: 'wrong-domain',
  DOMAIN_NOT_ALLOWLISTED: 'domain-not-allowlisted',
  REVOCATION_LIST_MISSING: 'revocation-list-missing',
  REVOCATION_LIST_STALE: 'revocation-list-stale',
  REVOCATION_LIST_ROLLBACK: 'revocation-list-rollback',
  REVOKED: 'revoked',
  WRONG_PERIOD: 'wrong-period',
  OVER_DECLARED_SIZE: 'over-declared-size',
  OVER_CAP: 'over-cap',
  REPLAYED: 'replayed',
  WRONG_REQUEST: 'wrong-request',
});

export class AttestationError extends Error {
  constructor(reason, detail) {
    super(detail ? `${reason}: ${detail}` : reason);
    this.reason = reason;
    this.detail = detail || '';
  }
}

function refuse(reason, detail) {
  throw new AttestationError(reason, detail);
}

// encoding ------------------------------------------------------------------------------------

const BASE64URL = /^[A-Za-z0-9_-]+$/;

export function toBase64url(bytes) {
  return Buffer.from(bytes).toString('base64url');
}

// strict: node's decoder skips characters it does not know, so check the alphabet and that the
// bytes encode back to the same text. one text, one byte string.
export function fromBase64url(text, what) {
  if (typeof text !== 'string' || !BASE64URL.test(text)) refuse(REFUSAL.MALFORMED, `${what} is not base64url`);
  const bytes = Buffer.from(text, 'base64url');
  if (bytes.toString('base64url') !== text) refuse(REFUSAL.MALFORMED, `${what} is not canonical base64url`);
  return bytes;
}

function contextLine(type, version) {
  return Buffer.from(`sirven attestation ${type} v${version}\n`, 'utf8');
}

// keys ----------------------------------------------------------------------------------------

export function generateSigningKey() {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  return { privateKey, publicKey };
}

// the raw 32 public key bytes, base64url. this is how keys travel inside signed payloads.
export function publicKeyText(key) {
  const publicKey = key.type === 'private' ? createPublicKey(key) : key;
  const jwk = publicKey.export({ format: 'jwk' });
  return jwk.x;
}

export function publicKeyFromText(text) {
  const raw = fromBase64url(text, 'public key');
  if (raw.length !== 32) refuse(REFUSAL.MALFORMED, 'public key is not 32 bytes');
  return createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: text }, format: 'jwk' });
}

// a key identifier: the first 16 bytes of the SHA-256 of the raw public key, base64url.
export function keyIdentifier(key) {
  const text = typeof key === 'string' ? key : publicKeyText(key);
  return toBase64url(createHash('sha256').update(fromBase64url(text, 'public key')).digest().subarray(0, 16));
}

export function privateKeyToPem(privateKey) {
  return privateKey.export({ format: 'pem', type: 'pkcs8' });
}

export function privateKeyFromPem(pem) {
  const key = createPrivateKey(pem);
  if (key.asymmetricKeyType !== 'ed25519') throw new Error('signing key is not Ed25519');
  return key;
}

// signed objects ------------------------------------------------------------------------------

export function signObject(type, payload, privateKey) {
  const bytes = Buffer.from(JSON.stringify(payload), 'utf8');
  const signature = sign(null, Buffer.concat([contextLine(type, payload.version), bytes]), privateKey);
  return { sirven_attestation: payload.version, type, payload: toBase64url(bytes), signature: toBase64url(signature) };
}

// openSigned: check shape, version, and signature, then parse. the payload is never trusted
// before its signature is.
export function openSigned(object, expectedType, publicKey) {
  const { version, bytes, signature } = readSigned(object, expectedType);
  const message = Buffer.concat([contextLine(expectedType, version), bytes]);
  if (signature.length !== 64 || !verify(null, message, publicKey, signature)) {
    refuse(REFUSAL.BAD_SIGNATURE, `${expectedType} signature does not verify`);
  }
  return parsePayload(bytes, expectedType, version);
}

// readSigned: the shape checks that come before any key is known.
function readSigned(object, expectedType) {
  if (object === null || typeof object !== 'object' || Array.isArray(object)) refuse(REFUSAL.MALFORMED, `${expectedType} is not a JSON object`);
  const version = object.sirven_attestation;
  if (!Number.isInteger(version)) refuse(REFUSAL.MALFORMED, `${expectedType} has no format version`);
  if (!SUPPORTED_VERSIONS.includes(version)) refuse(REFUSAL.UNSUPPORTED_VERSION, `${expectedType} format version ${version}`);
  if (object.type !== expectedType) refuse(REFUSAL.MALFORMED, `expected a ${expectedType}, got ${JSON.stringify(object.type)}`);
  if (object.signature === undefined || object.signature === null || object.signature === '') {
    refuse(REFUSAL.UNSIGNED, `${expectedType} carries no signature`);
  }
  const bytes = fromBase64url(object.payload, `${expectedType} payload`);
  const signature = fromBase64url(object.signature, `${expectedType} signature`);
  return { version, bytes, signature };
}

function parsePayload(bytes, type, version) {
  let payload;
  try {
    payload = JSON.parse(bytes.toString('utf8'));
  } catch {
    refuse(REFUSAL.MALFORMED, `${type} payload is not JSON`);
  }
  if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) refuse(REFUSAL.MALFORMED, `${type} payload is not an object`);
  if (payload.version !== version || payload.type !== type) refuse(REFUSAL.MALFORMED, `${type} payload disagrees with its outer version or type`);
  return payload;
}

// unverified look inside a signed object. only for choosing which key to verify with; nothing
// read here is trusted until openSigned succeeds.
function peekPayload(object, expectedType) {
  const { version, bytes } = readSigned(object, expectedType);
  return parsePayload(bytes, expectedType, version);
}

// field checks --------------------------------------------------------------------------------

const DOMAIN_LABEL = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;

// normalizeDomain: lowercase, no trailing dot, plain host names only. no wildcards, ports,
// schemes, or paths in version 1: the allowlist names exact domains.
export function normalizeDomain(domain) {
  if (typeof domain !== 'string') return null;
  const text = domain.trim().toLowerCase().replace(/\.$/, '');
  if (text.length === 0 || text.length > 253) return null;
  const labels = text.split('.');
  if (labels.length < 2 || !labels.every((label) => DOMAIN_LABEL.test(label))) return null;
  return text;
}

// the cap period a moment falls in: the calendar month in universal time, like 2026-10.
export function periodOf(seconds) {
  return new Date(seconds * 1000).toISOString().slice(0, 7);
}

const USER_HANDLE = /^[a-z0-9][a-z0-9._-]{0,63}$/;

export function validUserHandle(user) {
  return typeof user === 'string' && USER_HANDLE.test(user);
}

function wholeSeconds(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

function wholeBytes(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

export function nowSeconds() {
  const injected = process.env.SIRVEN_ATTESTATION_NOW;
  if (injected !== undefined && injected !== '') {
    const value = Number(injected);
    if (!wholeSeconds(value)) throw new Error('SIRVEN_ATTESTATION_NOW must be whole seconds since the epoch');
    return value;
  }
  return Math.floor(Date.now() / 1000);
}

// certification requests ----------------------------------------------------------------------

const AUDIENCE = /^[A-Za-z0-9_-]{8,64}$/;

export function validAudience(audience) {
  return typeof audience === 'string' && AUDIENCE.test(audience);
}

// a peer's identifier: random, made once when the peer is set up. envelopes name the peer they
// are for, so an envelope seen on the way to one peer cannot be spent at another.
export function newPeerIdentifier() {
  return toBase64url(randomBytes(16));
}

// makeCertificationRequest: on the user's device. signed with the device key itself, so the
// issuer knows whoever asks for the certificate holds the private key.
export function makeCertificationRequest({ userPrivateKey, user, now }) {
  if (!validUserHandle(user)) throw new Error(`not a valid user handle: ${user}`);
  const payload = {
    version: FORMAT_VERSION,
    type: 'certification-request',
    user,
    public_key: publicKeyText(userPrivateKey),
    key: keyIdentifier(userPrivateKey),
    issued_at: now,
  };
  return signObject('certification-request', payload, userPrivateKey);
}

// openCertificationRequest: on the issuer. verifies the request against the key it carries.
export function openCertificationRequest(request) {
  const claimed = peekPayload(request, 'certification-request');
  const payload = openSigned(request, 'certification-request', publicKeyFromText(claimed.public_key));
  if (!validUserHandle(payload.user)) refuse(REFUSAL.MALFORMED, 'certification request user handle');
  if (payload.key !== keyIdentifier(payload.public_key)) refuse(REFUSAL.MALFORMED, 'certification request key identifier does not match its public key');
  return payload;
}

// certificates --------------------------------------------------------------------------------

// issueCertificate: the identity issuer binds a user handle to a public key the user's device
// generated. the issuer only ever sees the public key.
export function issueCertificate({ issuerPrivateKey, user, userPublicKey, issuedAt, expiresAt }) {
  if (!validUserHandle(user)) throw new Error(`not a valid user handle: ${user}`);
  if (!(wholeSeconds(issuedAt) && wholeSeconds(expiresAt) && expiresAt > issuedAt)) throw new Error('certificate needs issued_at before expires_at');
  const publicKey = typeof userPublicKey === 'string' ? userPublicKey : publicKeyText(userPublicKey);
  publicKeyFromText(publicKey);
  const payload = {
    version: FORMAT_VERSION,
    type: 'certificate',
    posture: POSTURE_IDENTITY,
    issuer: keyIdentifier(issuerPrivateKey),
    serial: toBase64url(randomBytes(12)),
    user,
    public_key: publicKey,
    key: keyIdentifier(publicKey),
    issued_at: issuedAt,
    expires_at: expiresAt,
  };
  return signObject('certificate', payload, issuerPrivateKey);
}

// trustedIssuers: a map from issuer key identifier to public key.
export function trustedIssuerMap(issuerPublicKeys) {
  const map = new Map();
  for (const key of issuerPublicKeys) {
    const publicKey = typeof key === 'string' ? publicKeyFromText(key) : key;
    map.set(keyIdentifier(publicKey), publicKey);
  }
  return map;
}

// openCertificate: verify a certificate against the trusted issuers. with ignoreTime it skips
// the validity window, for tracing an old envelope back to its user.
export function openCertificate(certificate, trustedIssuers, now, { ignoreTime = false } = {}) {
  const claimed = peekPayload(certificate, 'certificate');
  const issuerKey = trustedIssuers.get(claimed.issuer);
  if (!issuerKey) refuse(REFUSAL.UNTRUSTED_ISSUER, `certificate issuer ${claimed.issuer} is not trusted`);
  const payload = openSigned(certificate, 'certificate', issuerKey);
  if (payload.posture !== POSTURE_IDENTITY) refuse(REFUSAL.UNSUPPORTED_POSTURE, `certificate posture ${payload.posture}`);
  if (!validUserHandle(payload.user)) refuse(REFUSAL.CERTIFICATE_INVALID, 'certificate user handle');
  if (typeof payload.serial !== 'string' || payload.serial.length === 0) refuse(REFUSAL.CERTIFICATE_INVALID, 'certificate serial');
  publicKeyFromText(payload.public_key);
  if (payload.key !== keyIdentifier(payload.public_key)) refuse(REFUSAL.CERTIFICATE_INVALID, 'certificate key identifier does not match its public key');
  if (!(wholeSeconds(payload.issued_at) && wholeSeconds(payload.expires_at))) refuse(REFUSAL.CERTIFICATE_INVALID, 'certificate times');
  if (!ignoreTime) {
    if (now + CLOCK_SKEW_SECONDS < payload.issued_at) refuse(REFUSAL.CERTIFICATE_INVALID, 'certificate is not valid yet');
    if (now >= payload.expires_at) refuse(REFUSAL.CERTIFICATE_EXPIRED, `certificate expired at ${payload.expires_at}`);
  }
  return payload;
}

// revocation lists ----------------------------------------------------------------------------

// issueRevocationList: users and keys peers must refuse, with a sequence number that only goes
// up, so a peer can refuse an older list replayed to it, and a next_update after which a peer
// treats the list as stale and refuses everything until it has a newer one.
export function issueRevocationList({ issuerPrivateKey, sequence, issuedAt, nextUpdate, users = [], keys = [] }) {
  if (!(Number.isSafeInteger(sequence) && sequence >= 1)) throw new Error('revocation list sequence must be a whole number from 1');
  if (!(wholeSeconds(issuedAt) && wholeSeconds(nextUpdate) && nextUpdate > issuedAt)) throw new Error('revocation list needs issued_at before next_update');
  const payload = {
    version: FORMAT_VERSION,
    type: 'revocation-list',
    issuer: keyIdentifier(issuerPrivateKey),
    sequence,
    issued_at: issuedAt,
    next_update: nextUpdate,
    users: users.map(({ user, revoked_at, reason }) => ({ user, revoked_at, reason: reason || '' })),
    keys: keys.map(({ key, revoked_at, reason }) => ({ key, revoked_at, reason: reason || '' })),
  };
  return signObject('revocation-list', payload, issuerPrivateKey);
}

// openRevocationList: verify a list against the trusted issuers. with previousSequence, refuse
// a list that is not newer than the one the peer already has.
export function openRevocationList(list, trustedIssuers, { previousSequence = 0 } = {}) {
  const claimed = peekPayload(list, 'revocation-list');
  const issuerKey = trustedIssuers.get(claimed.issuer);
  if (!issuerKey) refuse(REFUSAL.UNTRUSTED_ISSUER, `revocation list issuer ${claimed.issuer} is not trusted`);
  const payload = openSigned(list, 'revocation-list', issuerKey);
  if (!(Number.isSafeInteger(payload.sequence) && payload.sequence >= 1)) refuse(REFUSAL.MALFORMED, 'revocation list sequence');
  if (!(wholeSeconds(payload.issued_at) && wholeSeconds(payload.next_update))) refuse(REFUSAL.MALFORMED, 'revocation list times');
  if (!Array.isArray(payload.users) || !Array.isArray(payload.keys)) refuse(REFUSAL.MALFORMED, 'revocation list entries');
  if (payload.sequence < previousSequence) {
    refuse(REFUSAL.REVOCATION_LIST_ROLLBACK, `revocation list sequence ${payload.sequence} is older than ${previousSequence}`);
  }
  return {
    ...payload,
    revokedUsers: new Set(payload.users.map((entry) => entry.user)),
    revokedKeys: new Set(payload.keys.map((entry) => entry.key)),
  };
}

// request envelopes ---------------------------------------------------------------------------

// signRequest: on the originator's device. the user's own key attests one request.
// a request digest is the SHA-256 of the exact request bytes, lowercase hexadecimal. when the
// originator passes one it is signed into the envelope, so the envelope covers that one request
// and nothing else; a peer that knows the bytes it is asked to carry checks it (step 5).
const REQUEST_DIGEST = /^[0-9a-f]{64}$/;

export function signRequest({ userPrivateKey, certificate, audience, domain, requestBytes, usedBytes, limitBytes = DEFAULT_CAP_BYTES, now, lifetime = DEFAULT_REQUEST_LIFETIME_SECONDS, requestDigest }) {
  const normalized = normalizeDomain(domain);
  if (!normalized) throw new Error(`not a plain domain name: ${domain}`);
  if (!validAudience(audience)) throw new Error('signing needs the identifier of the peer that will carry the request');
  if (!(wholeBytes(requestBytes) && wholeBytes(usedBytes) && wholeBytes(limitBytes))) throw new Error('byte counts must be whole numbers');
  if (!(Number.isSafeInteger(lifetime) && lifetime > 0 && lifetime <= MAX_REQUEST_LIFETIME_SECONDS)) {
    throw new Error(`lifetime must be 1 to ${MAX_REQUEST_LIFETIME_SECONDS} seconds`);
  }
  if (usedBytes + requestBytes > limitBytes) {
    throw new AttestationError(REFUSAL.OVER_CAP, `this request would bring the period to ${usedBytes + requestBytes} of ${limitBytes} bytes`);
  }
  if (requestDigest !== undefined && !REQUEST_DIGEST.test(requestDigest)) throw new Error('a request digest is 64 lowercase hexadecimal characters');
  const certificatePayload = peekPayload(certificate, 'certificate');
  if (certificatePayload.key !== keyIdentifier(userPrivateKey)) throw new Error('the certificate is for a different key than the one signing');
  const payload = {
    version: FORMAT_VERSION,
    type: 'request',
    posture: POSTURE_IDENTITY,
    credential: certificate,
    agent: AGENT_PERSONAL,
    user: certificatePayload.user,
    key: certificatePayload.key,
    audience,
    domain: normalized,
    cap: { period: periodOf(now), limit_bytes: limitBytes, used_bytes: usedBytes, request_bytes: requestBytes },
    issued_at: now,
    expires_at: now + lifetime,
    nonce: toBase64url(randomBytes(16)),
  };
  if (requestDigest !== undefined) payload.request_digest = requestDigest;
  return signObject('request', payload, userPrivateKey);
}

// verifyRequest: on the peer. checks the envelope against the request the peer is actually
// asked to carry, its own allowlist, its revocation list, its own ledger, and its nonce memory.
//
//   context.trustedIssuers   map from issuer key identifier to public key (trustedIssuerMap)
//   context.revocationList   the peer's current list, from openRevocationList
//   context.audience         this peer's own identifier
//   context.allowlist        a Set of domains this peer carries traffic to
//   context.host             the host the request is going to
//   context.requestBytes     the size of the request the peer is asked to carry
//   context.now              seconds since the epoch
//   context.capBytes         this peer's cap per user per period (default 5 gigabytes)
//   context.carriedBytes(user, period)   bytes this peer has already carried for that user
//   context.seenNonce(nonce)             true when this peer has already accepted that nonce
//   context.requestDigest    optional: the SHA-256 of the exact bytes the peer is asked to carry.
//                            when given, the envelope must carry the same digest
//
// returns {accepted: true, ...} or {accepted: false, reason, detail}. every refusal names one
// of the REFUSAL reasons; a peer carries nothing unless accepted is true.
export function verifyRequest(envelope, context) {
  try {
    return { accepted: true, ...checkRequest(envelope, context) };
  } catch (error) {
    if (error instanceof AttestationError) return { accepted: false, reason: error.reason, detail: error.detail };
    return { accepted: false, reason: REFUSAL.MALFORMED, detail: String(error && error.message) };
  }
}

function checkRequest(envelope, context) {
  const { trustedIssuers, revocationList, allowlist, host, requestBytes, now } = context;
  const capBytes = context.capBytes ?? DEFAULT_CAP_BYTES;
  const carriedBytes = context.carriedBytes || (() => 0);
  const seenNonce = context.seenNonce || (() => false);

  if (typeof envelope === 'string') {
    try {
      envelope = JSON.parse(envelope);
    } catch {
      refuse(REFUSAL.MALFORMED, 'envelope is not JSON');
    }
  }
  if (envelope === null || envelope === undefined) refuse(REFUSAL.UNSIGNED, 'no envelope');

  // 1. the envelope signature, by the key its own certificate names. which key to try comes
  //    from the unverified payload; the certificate is verified in step 2 before anything in
  //    the payload is believed.
  const claimed = peekPayload(envelope, 'request');
  if (!SUPPORTED_POSTURES.includes(claimed.posture)) refuse(REFUSAL.UNSUPPORTED_POSTURE, `posture ${claimed.posture}`);
  const certificateClaimed = peekPayload(claimed.credential, 'certificate');
  const payload = openSigned(envelope, 'request', publicKeyFromText(certificateClaimed.public_key));

  // 2. the certificate, by a trusted identity issuer.
  const certificate = openCertificate(payload.credential, trustedIssuers, now);
  if (payload.user !== certificate.user || payload.key !== certificate.key) refuse(REFUSAL.USER_MISMATCH, 'envelope user or key differs from its certificate');
  if (payload.agent !== AGENT_PERSONAL) refuse(REFUSAL.NOT_PERSONAL_AGENT, `agent ${payload.agent}`);

  // 3. revocation. no list, or a stale one, refuses everything: the peer fails closed.
  if (!revocationList) refuse(REFUSAL.REVOCATION_LIST_MISSING, 'this peer has no revocation list');
  if (!trustedIssuers.has(revocationList.issuer) || revocationList.issuer !== certificate.issuer) {
    refuse(REFUSAL.REVOCATION_LIST_MISSING, 'this peer has no revocation list from the certificate issuer');
  }
  if (now >= revocationList.next_update) refuse(REFUSAL.REVOCATION_LIST_STALE, `revocation list was due for renewal at ${revocationList.next_update}`);
  if (revocationList.revokedUsers.has(certificate.user)) refuse(REFUSAL.REVOKED, `user ${certificate.user} is revoked`);
  if (revocationList.revokedKeys.has(certificate.key)) refuse(REFUSAL.REVOKED, `key ${certificate.key} is revoked`);

  // 4. time.
  if (!(wholeSeconds(payload.issued_at) && wholeSeconds(payload.expires_at))) refuse(REFUSAL.MALFORMED, 'envelope times');
  if (payload.expires_at - payload.issued_at > MAX_REQUEST_LIFETIME_SECONDS) refuse(REFUSAL.LIFETIME_TOO_LONG, `${payload.expires_at - payload.issued_at} seconds`);
  if (now + CLOCK_SKEW_SECONDS < payload.issued_at) refuse(REFUSAL.NOT_YET_VALID, `issued at ${payload.issued_at}, now ${now}`);
  if (now >= payload.expires_at) refuse(REFUSAL.EXPIRED, `expired at ${payload.expires_at}, now ${now}`);

  // 5. scope: the envelope names this peer, and the envelope's domain, the host actually
  //    requested, and this peer's allowlist all agree.
  if (!validAudience(context.audience)) refuse(REFUSAL.WRONG_AUDIENCE, 'this peer has no identifier to check the envelope against');
  if (payload.audience !== context.audience) refuse(REFUSAL.WRONG_AUDIENCE, 'envelope is addressed to a different peer');
  const domain = normalizeDomain(payload.domain);
  if (!domain || domain !== payload.domain) refuse(REFUSAL.MALFORMED, 'envelope domain');
  if (normalizeDomain(host) !== domain) refuse(REFUSAL.WRONG_DOMAIN, `envelope is for ${domain}, request goes to ${host}`);
  if (!allowlist || !allowlist.has(domain)) refuse(REFUSAL.DOMAIN_NOT_ALLOWLISTED, `${domain} is not on this peer's allowlist`);
  if (context.requestDigest !== undefined && payload.request_digest !== context.requestDigest) {
    refuse(REFUSAL.WRONG_REQUEST, 'envelope does not cover the exact request this peer is asked to carry');
  }

  // 6. cap: the user's own declaration, and this peer's own ledger, both have to fit.
  const cap = payload.cap;
  if (!cap || typeof cap !== 'object' || !wholeBytes(cap.limit_bytes) || !wholeBytes(cap.used_bytes) || !wholeBytes(cap.request_bytes) || typeof cap.period !== 'string') {
    refuse(REFUSAL.MALFORMED, 'envelope cap');
  }
  if (cap.period !== periodOf(now) || cap.period !== periodOf(payload.issued_at)) refuse(REFUSAL.WRONG_PERIOD, `envelope period ${cap.period}, now ${periodOf(now)}`);
  if (!wholeBytes(requestBytes)) refuse(REFUSAL.MALFORMED, 'request size');
  if (requestBytes > cap.request_bytes) refuse(REFUSAL.OVER_DECLARED_SIZE, `request is ${requestBytes} bytes, envelope declared ${cap.request_bytes}`);
  const limit = Math.min(cap.limit_bytes, capBytes);
  if (cap.used_bytes + cap.request_bytes > limit) refuse(REFUSAL.OVER_CAP, `declared ${cap.used_bytes} used plus ${cap.request_bytes} exceeds ${limit}`);
  const carried = carriedBytes(certificate.user, cap.period);
  if (carried + requestBytes > capBytes) refuse(REFUSAL.OVER_CAP, `this peer already carried ${carried} bytes for ${certificate.user} in ${cap.period}`);

  // 7. replay.
  if (typeof payload.nonce !== 'string' || payload.nonce.length < 16) refuse(REFUSAL.MALFORMED, 'envelope nonce');
  if (seenNonce(payload.nonce)) refuse(REFUSAL.REPLAYED, `nonce ${payload.nonce} was already accepted`);

  return {
    user: certificate.user,
    key: certificate.key,
    certificate_serial: certificate.serial,
    issuer: certificate.issuer,
    audience: payload.audience,
    domain,
    period: cap.period,
    request_bytes: requestBytes,
    nonce: payload.nonce,
    expires_at: payload.expires_at,
    request_digest: payload.request_digest ?? null,
    declared_bytes: cap.request_bytes,
  };
}

// traceEnvelope: abuse traceability. given an envelope whose signatures verify, name the user
// who sent it, even after it expired or the user was revoked. a peer keeps envelopes it carried
// so an abuse report can be traced back through the issuer to a person.
export function traceEnvelope(envelope, trustedIssuers) {
  if (typeof envelope === 'string') envelope = JSON.parse(envelope);
  const claimed = peekPayload(envelope, 'request');
  const certificateClaimed = peekPayload(claimed.credential, 'certificate');
  const payload = openSigned(envelope, 'request', publicKeyFromText(certificateClaimed.public_key));
  const certificate = openCertificate(payload.credential, trustedIssuers, 0, { ignoreTime: true });
  if (payload.user !== certificate.user || payload.key !== certificate.key) refuse(REFUSAL.USER_MISMATCH, 'envelope user or key differs from its certificate');
  return {
    user: certificate.user,
    key: certificate.key,
    certificate_serial: certificate.serial,
    issuer: certificate.issuer,
    posture: payload.posture,
    agent: payload.agent,
    audience: payload.audience,
    domain: payload.domain,
    cap: payload.cap,
    issued_at: payload.issued_at,
    expires_at: payload.expires_at,
    nonce: payload.nonce,
  };
}

// registry versions ---------------------------------------------------------------------------
// the site-allowlist registry (lib/allowlist_review.py) is signed per published version by the
// identity issuer key, so a node can prove the copy it fetched came from sirven, not only that it
// arrived intact. the payload carries the registry's exact bytes as base64url, and a validity
// window: a node stops carrying for anyone once the window ends without a newer version.

export const MAX_REGISTRY_VALIDITY_SECONDS = 30 * 86400;

export function signRegistry({ issuerPrivateKey, registryBytes, publishedAt, expiresAt }) {
  if (!(wholeSeconds(publishedAt) && wholeSeconds(expiresAt) && publishedAt < expiresAt)) throw new Error('registry validity window is invalid');
  if (expiresAt - publishedAt > MAX_REGISTRY_VALIDITY_SECONDS) throw new Error(`a registry version is valid for at most ${MAX_REGISTRY_VALIDITY_SECONDS} seconds`);
  const bytes = Buffer.from(registryBytes);
  JSON.parse(bytes.toString('utf8'));
  const payload = {
    version: FORMAT_VERSION,
    type: 'registry',
    issuer: keyIdentifier(issuerPrivateKey),
    registry: toBase64url(bytes),
    registry_sha256: createHash('sha256').update(bytes).digest('hex'),
    published_at: publishedAt,
    expires_at: expiresAt,
  };
  return signObject('registry', payload, issuerPrivateKey);
}

// openRegistry: on a node. returns {issuer, registry_bytes, registry_sha256, published_at,
// expires_at} once the signature verifies against a trusted issuer. time is the caller's check.
export function openRegistry(signed, trustedIssuers) {
  const claimed = peekPayload(signed, 'registry');
  const issuerKey = trustedIssuers.get(claimed.issuer);
  if (!issuerKey) refuse(REFUSAL.UNTRUSTED_ISSUER, `registry signed by ${claimed.issuer}`);
  const payload = openSigned(signed, 'registry', issuerKey);
  const bytes = fromBase64url(payload.registry, 'registry');
  if (createHash('sha256').update(bytes).digest('hex') !== payload.registry_sha256) refuse(REFUSAL.MALFORMED, 'registry checksum');
  if (!(wholeSeconds(payload.published_at) && wholeSeconds(payload.expires_at) && payload.published_at < payload.expires_at)) refuse(REFUSAL.MALFORMED, 'registry validity window');
  return { issuer: payload.issuer, registry_bytes: bytes, registry_sha256: payload.registry_sha256, published_at: payload.published_at, expires_at: payload.expires_at };
}
