# Face ID approval relay: a link-based step-up for purchases Instinct makes

Status: research and design, 2026-10-14. No code written yet. This document
is the recommendation for how sirven should let Jose approve, from his phone,
a purchase his agent (Instinct) is making on his behalf on another device.

## What this is, and what it is not

The use case is a one-time approval relay, a step-up second factor for an
action the device owner is already taking on his own devices. Concretely:
Jose is out walking and texts Instinct to buy something. His iPad is at home,
plugged into his laptop, and the laptop is driving the iPad through the sirven
phone interface. The purchase reaches a point that needs Face ID (Apple's
face-recognition unlock), but Jose is not holding the iPad. He wants Instinct
to text him a link. He opens it on his phone, the page requires Face ID, and
that approval is passed back to the iPad session so the pending purchase can
proceed.

This is the owner approving his own action on his own devices. It is a consent
and authorization design, the same shape as a step-up second factor on a bank
login. It is explicitly **not** any of the following, and every design choice
below is made to keep it that way:

- It does not spoof, replay, forge, or inject anyone's biometric.
- It does not move a face template or any biometric data off any device.
- It never helps one person authenticate as another. The relay proves that
  Jose, holding his own enrolled phone, approved one specific action. It
  proves nothing else and releases nothing else.
- It does not bypass Apple's own Face ID. Where Apple's operating system
  demands the local device's Face ID, this design stops and says so, rather
  than pretending to satisfy it. See "The hard limit" below.

If any requested extension would cross one of those lines, the answer is no,
and the reason is that the primitive stops being consent and becomes
impersonation.

## Research

### 1. The Face ID teardown

I could not find the exact recent Twitter/X teardown thread Jose saw. Search
surfaced Apple's own documentation, reference articles, and a single
unverified 2026 teardown report (attributed to REWA Technology) claiming the
iPhone 18 Pro moved the infrared camera under the display. I could not confirm
that against the teardown itself, so I am not relying on it.

What every credible source agrees on, and what matters for this design:

- Face ID uses the TrueDepth camera system: a dot projector that casts about
  30,000 infrared dots to build a depth map of the face, plus an infrared
  camera and a flood illuminator so it works in the dark.
- A portion of the Neural Engine, running inside the Secure Enclave (a
  separate, sealed coprocessor on Apple's chip), turns the depth map and
  infrared image into a mathematical representation and compares it to the
  enrolled face data.
- That comparison happens entirely on the device. Apple states the data in the
  Secure Enclave cannot be read by the operating system, by apps, by the user,
  or by Apple, and that the face representation never leaves the device.

What this implies for a design like ours: the biometric is local and sealed by
construction, so there is no path, and no need, to transport "a Face ID" from
one device to another. The only thing that can legitimately cross the network
is a signed statement that a local Face ID check succeeded on a device Jose
controls. That statement is exactly what the web authentication standard
produces (next section). What this does not imply: it gives us no way, and no
right, to satisfy another device's local Face ID prompt remotely.

Sources: [Apple, About Face ID advanced technology](https://support.apple.com/en-us/102381),
[Apple, Face ID Security Guide (2017)](https://www.apple.com/business-docs/FaceID_Security_Guide.pdf),
[AppleInsider, Face ID](https://appleinsider.com/inside/face-id),
[Wikipedia, Face ID](https://en.wikipedia.org/wiki/Face_ID).

### 2. Decagon

Jose recalled that Decagon, a reputable company, shipped something like this.
The comparison only partly holds, and I want to be honest about where it
breaks.

Decagon builds customer-service artificial-intelligence agents. Its published
materials and third-party reviews describe three relevant capabilities:
identity verification as a task its agents perform (including voice
authentication), guardrails that route sensitive operations such as refunds
and account-takeover cases, and human handoff or escalation to a person.

Where the analogy holds: Decagon gates sensitive agent actions behind a
verification or a human, which is the same instinct as this design, an agent
pausing for a trusted approval before doing something consequential.

Where it breaks: I found no evidence that Decagon ships a cryptographic
approval relay that binds a biometric-backed signature to one specific pending
action across devices. Its verification is a customer proving who they are to a
support agent, not an owner releasing one agent-initiated purchase. So Decagon
is a precedent for "agents should pause for human approval on sensitive
actions," not a precedent for the specific mechanism proposed here. Treat the
third-party capability claims as secondary; Decagon's own documentation would
be the place to confirm.

Sources: [eesel, Decagon guide](https://www.eesel.ai/blog/decagon-for-saas),
[myaskai, AI customer service identity verification](https://myaskai.com/blog/best-ai-customer-service-identity-verification-2026),
[twig, Decagon alternatives and human handoff](https://www.twig.so/blog/best-decagon-alternatives-strong-human-handoff).

### 3. The legitimate building block: passkeys and the web authentication standard

A passkey is a public-and-private key pair bound to a website identity (the
relying party), where the private key lives in the device's secure hardware and
is used only after a local user-verification check. On an Apple device that
local check is Face ID or Touch ID, performed by the Secure Enclave; the
biometric never leaves the device, and the website only ever receives a
signature.

The web authentication standard (published by the World Wide Web Consortium as
WebAuthn) is how a web page asks for that signature. The flow for an approval
is an assertion ceremony:

1. The sirven backend issues a random challenge to the relay page.
2. The page calls the browser's credential interface
   (`navigator.credentials.get`) asking for Jose's passkey, with
   user verification required.
3. The phone runs Face ID locally. Only on success does the Secure Enclave
   sign.
4. The browser returns an assertion: `authenticatorData` plus a
   `clientDataJSON` object that records the challenge, the ceremony type
   (`webauthn.get`), and the origin. The authenticator's signature covers
   `authenticatorData` concatenated with the SHA-256 (256-bit Secure Hash
   Algorithm) hash of `clientDataJSON`.
5. The backend verifies: the signature against Jose's enrolled public key; that
   the challenge equals the exact value it issued (constant-time comparison);
   that the origin and relying-party identifier are sirven's own; and, the part
   that makes Face ID load-bearing, that the user-verification flag in the
   signed `authenticatorData` is set. If that bit is not set, the signature
   does not prove a Face ID happened and the approval is refused.

Binding the signature to one action (transaction binding). Rather than issuing
an opaque random challenge, the backend derives the challenge from the action
itself: a hash over the action descriptor (what is being bought, the amount,
the currency, the merchant), a random nonce, the target iPad session
identifier, and an expiry. Because the authenticator signs over the challenge,
the resulting signature is proof that Jose approved that exact purchase, not a
reusable "yes." The payments industry calls this dynamic linking; the European
Union's regulatory technical standards for strong customer authentication
(Article 5 of Regulation 2018/389) make it mandatory for remote electronic
payments, folding amount, currency, and payee into the authentication so the
signature attests to that specific payment. We adopt the same discipline even
though sirven is not a regulated payment institution, because it is what turns
a face login into a per-action authorization.

Apple specifics and limits:

- The relying-party identifier must be a domain sirven controls, served over
  HTTPS. For a pure web page using the browser credential interface, that is
  all that is required: a domain, HTTPS, and a WebAuthn server. No Apple
  developer entitlement is needed.
- If the relay were instead a screen inside a native sirven app using Apple's
  AuthenticationServices framework, the app would additionally need an
  associated-domains entitlement with a `webcredentials` entry matching the
  relying-party identifier, and an apple-app-site-association file served over
  HTTPS without redirects. This is the reason the recommendation below prefers
  the pure web page.
- Passkeys sync through iCloud Keychain, so the passkey Jose enrolls once is
  available on his phone even if created elsewhere. Syncing is a convenience,
  not a weakening: each use still requires a live local Face ID.

Sources: [mojoauth, binding a passkey challenge to a transaction](https://mojoauth.com/blog/passkey-step-up-authentication-payments),
[mojoauth, server-side passkey authentication](https://mojoauth.com/blog/server-side-passkey-authentication-what-the-spec-doesnt-tell-you.md),
[Apple Developer, supporting passkeys](https://developer.apple.com/documentation/authenticationservices/supporting-passkeys),
[passkeys.dev, iOS reference](https://passkeys.dev/docs/reference/ios).

## The design: a link-based approval relay for sirven and Instinct

### Components

- Pending-action store (backend). When the iPad-driving session reaches a step
  that needs approval, it does not proceed. It registers a pending action: a
  fresh action identifier, the action descriptor (human-readable: what, how
  much, which merchant), the iPad session identifier, a creation time, a short
  expiry, and a state of `pending`. Nothing is released yet.
- Relay page (sirven-hosted, HTTPS, sirven's own domain). A single-purpose
  page tied to one action identifier. It shows the plain-language action
  descriptor so Jose sees exactly what he is approving, then runs the web
  authentication assertion ceremony.
- Verifier (backend). Checks the assertion as in section 3, enforces one-time
  use and expiry, and on success moves the action from `pending` to `approved`.
- Consumer (the iPad side). The sirven phone session that paused is told the
  action is approved and proceeds with exactly that action.

### Enrollment, once

Jose enrolls one passkey against sirven's relying-party identifier, from his
phone, with a normal Face ID prompt. The backend stores the passkey's
credential identifier and public key as "Jose's approval key." This is the only
standing secret, and it is a public key, so the store holds nothing that can
impersonate him. Enrollment is a deliberate, owner-only act, the same category
as binding a real person to a sirven user handle in the attestation layer,
which the attestation document already reserves as Jose's call.

### The approval ceremony, step by step

1. Instinct, driving the iPad, reaches a purchase that needs approval. The
   session pauses and registers a pending action. No bytes of the purchase go
   through.
2. Instinct texts Jose a link to the relay page for that one action
   identifier. (Per the sirven hard rules, sending that text is an outward
   action; it is Instinct speaking to its owner about its owner's own pending
   action, which is the intended path, but the message content is logged.)
3. Jose opens the link on his phone. The page shows the action descriptor in
   plain language.
4. The page requests an assertion with user verification required, over a
   challenge the backend derived from the action descriptor, a random nonce,
   the iPad session identifier, and the expiry.
5. Jose's phone runs Face ID. The Secure Enclave signs only on success.
6. The backend verifies the assertion, including that the user-verification
   flag is set and the challenge matches the pending action. On success it
   marks that one action `approved` and records the nonce as spent.
7. The paused iPad session observes `approved` for its action identifier and
   proceeds with exactly that purchase. It does not gain a general ability to
   approve anything else.

### What is signed and bound

The signature covers the challenge, and the challenge is derived from: the
action descriptor (what, amount, currency, merchant), a random nonce, the iPad
session identifier, and the expiry. This binds the approval to one action, for
one session, usable once, within a short window. This mirrors the attestation
layer's existing envelope discipline, where each request names the one peer it
is for, one domain, a short lifetime, and a one-time nonce, so an envelope seen
on its way to one place cannot be spent at another. The action identifier and
iPad session identifier here play the role that the audience (peer identifier)
plays there.

### Expiry, replay protection, one-time use

Reuse the attestation layer's primitives rather than inventing new ones:

- Short lifetime. Pending actions expire quickly, on the order of the
  attestation envelope's 120-second default and 300-second maximum. An expired
  action cannot be approved; Instinct must register a fresh one.
- One-time nonce. The nonce in the challenge is recorded as spent on first
  successful verification, using the same accept-each-nonce-once discipline the
  peer audit log already implements. A replayed assertion is refused.
- Audience binding. The challenge names the one iPad session identifier, so an
  approval relayed for one session cannot release a pending action in another.
- One-time state transition. The pending action moves `pending` to `approved`
  exactly once; a second attempt to consume it finds no `pending` action.

### The optional brief approval window

Jose's framing allowed that one approval might also cover other Face ID prompts
the same iPad session raises in that moment. This is supported only under a
tight rule, and it is off by default: after a successful approval, the backend
may open a short, explicit window scoped to that one iPad session, during which
further approvals that session raises are released, but each one is still
individually described, individually bound to its own action descriptor and
nonce, and individually logged. The window is a convenience for a burst of
steps in a single checkout, not a blanket "approve everything." It has its own
short expiry and closes when the session ends. If this adds meaningful risk for
little benefit, drop it; the single-action path is the safe core.

### How the iPad side consumes the approval

The iPad is driven by the laptop through the sirven phone interface
(WebDriverAgent over the Universal Serial Bus, loopback HTTP, per-session
owner consent). The consumer path is therefore inside the already-consented
phone session:

- For a purchase sirven itself mediates, or a web checkout flow sirven drives,
  the paused step resumes once the backend reports `approved` for the action
  identifier. This is the realistic scope and it is fully in sirven's control.
- The iPad session polls (or is notified by) the backend for the state of its
  own action identifier only. It cannot query or release other actions.

### Logging

Every step is logged in plain language, consistent with the phone interface and
runtime's existing honest-log posture: the pending action and its descriptor,
the text Instinct sent, the verification result (approved, denied, expired, or
failed), the nonce marked spent, and the resumed action. The logs record that
an approval happened and for what; they never record biometric data, because
none is ever transmitted.

### Denial and timeout

- Denial. If Jose closes the page or the Face ID check fails, no `approved`
  transition happens. The pending action stays `pending` until it expires, then
  is refused. The iPad session reports the purchase was not approved and does
  not proceed. The runtime's rule that a block is a result, never retried
  around, applies: Instinct does not seek another path to the purchase.
- Timeout. If the window expires before approval, the action is refused with an
  explicit expired state. Instinct may register a fresh pending action and send
  a new link, but cannot reuse the old one.

## The hard limit

There is a wall, and it must be stated plainly because it bounds the whole
product.

A purchase inside a native Apple-operating-system app on the iPad that demands
the iPad's own Face ID cannot be satisfied by a signature from another device.
Apple's local authentication binds that prompt to the iPad's own Secure Enclave
and its physically present, enrolled biometric. There is no supported interface
to inject a remote Face ID result into another device's local prompt, and
building one would mean defeating the local biometric, which this design
refuses to do. Apple Pay's own biometric confirmation (the double-click side
button) and App Store or iTunes purchase confirmations fall on the far side of
this wall.

Therefore the realistic scope is:

- In scope: purchases and web checkout flows that sirven mediates, where the
  approval gate is sirven's own step-up and sirven controls when the paused
  step resumes. The relay works cleanly here.
- Out of scope: arbitrary third-party native-app Face ID prompts, Apple Pay's
  biometric confirmation, and App Store purchase confirmations. For those the
  relay cannot and must not stand in. The honest product answer for those is
  that the iPad holder must be present, or the purchase must be routed through
  a sirven-mediated web flow instead of a native-app prompt.

## Reuse map

What the repository already provides that this design builds on:

- `lib/attestation/` (documented in `docs/attestation.md`): Ed25519 (the
  Edwards-curve digital signature scheme) signed envelopes, one-time nonces,
  short lifetimes, audience binding, and the one-key-one-person certificate
  model. The challenge-binding and replay-protection parts of this design are
  the same primitives applied to an approval instead of a carried request.
- `lib/phone_bridge.py` and `sirven phone` (documented in
  `docs/phone-interface.md`): the consented, logged, loopback-only path that
  drives the plugged-in iPad. The consumer side of the relay lives inside an
  already-open phone session.
- `lib/sirven_runtime/` (documented in `docs/runtime-interface.md`): the
  honest decision-log posture and the rule that a block is a result and is
  never retried around. The relay's denial and timeout behavior follows it.

## What needs Jose

- Enroll one passkey, once, against sirven's relying-party identifier from his
  phone. Owner-only, the same category of deliberate act as binding an identity
  in the attestation layer.
- Provide a domain sirven controls, with HTTPS, to serve as the relying-party
  identifier and host the relay page.
- An Apple developer entitlement (associated domains with a `webcredentials`
  entry) is needed only if the relay is built as a screen in a native sirven
  app. The recommended pure-web relay page does not need it. This is Jose's
  choice between the two implementations.

## Recommendation and verdict

The relay is feasible and safe when built as a transaction-bound passkey
step-up: a sirven-hosted web page, one passkey Jose enrolls once, user
verification required (Face ID), and a challenge derived from the specific
pending action so the resulting signature authorizes that one purchase and
nothing else. It reuses the attestation layer's nonce, lifetime, and
audience-binding discipline for replay protection and one-action scope, and the
phone interface's consented session for the iPad side. It never transports a
biometric and never impersonates anyone.

The honest scope limit: it covers sirven-mediated and web purchase flows, which
is the use case Jose described. It cannot and must not satisfy a native Apple
app's own Face ID prompt on the iPad (Apple Pay, App Store, third-party app
biometrics); that wall is enforced by the operating system and is correct.

Recommended next step, when the parent moves this from design to build: a
pure-web relay page plus a small backend verifier, reusing `lib/attestation/`
for challenge binding and nonce retirement, wired to the pending-action store
that the iPad phone session checks.
