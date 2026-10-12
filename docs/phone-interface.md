# Phone interface: your agent drives your own plugged-in iPhone

Status: built and tested against a fake phone, 2026-10-11. Not yet run against a real iPhone;
see "What is verified" at the end.

When your iPhone is plugged into your Mac over USB (the phone's charging cable) and has trusted
the Mac, sirven can let your agent read the phone's screen, tap, type, swipe, and open apps. The
automation runs in the phone's real apps, signed into your own accounts, so it can do things in
apps that have no public interface, like booking a ride.

This is **one personal phone, yours**. It is not the multi-phone device-farm tier described in
the scope, which stays deferred. sirven refuses to drive a phone when more than one is plugged in.

The code is `lib/phone_bridge.py` (python standard library only) behind `sirven phone`. The
approach comes from the iPhone-use project; see "Credit" below.

## How it works

```
agent  --HTTP, bearer token-->  sirven phone serve (127.0.0.1 only)
                                   | consent check, safety checks, plain-language log
                                   v
                                the Mac's USB multiplexer (/var/run/usbmuxd)
                                   v
                                WebDriverAgent on the phone, port 8100
```

- **Detection.** sirven asks the Mac's USB multiplexer which phones are attached. A phone
  counts as trusted when the multiplexer holds a pairing record for it, which exists only after
  you tapped Trust on the phone. sirven checks that the record exists and never reads it out,
  stores it, or logs it. The phone's serial number never appears in any output either.
- **Driving.** WebDriverAgent (an open source test runner from the Appium project) runs on the
  phone and accepts commands over HTTP. sirven reaches it through the USB multiplexer directly,
  so no separate port forwarder is needed. `SIRVEN_WEBDRIVERAGENT_URL` points sirven at a
  forwarder you already run instead, and is refused unless it is loopback HTTP.
- **No analytics.** sirven sends nothing anywhere. (iPhone-use itself ships anonymous
  analytics that are on by default; none of that code is here.)

## Setup, once

`sirven phone setup --team TEAM --bundle BUNDLE` prints the plan. sirven never runs it for you,
because it signs software with your Apple account.

1. On the phone: plug it in, unlock it, tap Trust.
2. On the phone: Settings > Privacy & Security > Developer Mode, on, then restart.
3. On the Mac: full Xcode, signed into your Apple account.
4. Clone WebDriverAgent at the commit iPhone-use pins, and build its runner for your phone
   with `xcodebuild ... test`, using your own development team and a bundle name you own.
5. On the phone, the first time: trust your developer certificate (Settings > General, the
   device management page), and turn on the user interface automation switch under
   Settings > Developer.
6. Keep that `xcodebuild` running, then `sirven phone status`.

## Consent: opt in per session, owner only

The agent cannot turn phone control on. Only you can, at a terminal, by typing yes:

| Command | What it does |
|---|---|
| `sirven phone allow [--minutes N]` | Open a phone session, 30 minutes by default, at most 240. |
| `sirven phone allow --allow-submit` | The same, and the agent may press return. Without it, any text with a newline, or a submit, is refused, because a return can send a message or a form. |
| `sirven phone stop` | End the session now. The next agent request is refused. |
| `sirven phone holds` | Actions waiting for your approval. |
| `sirven phone approve HOLD` / `deny HOLD` | Decide one held action. An approval is good once, for that exact action, for five minutes. |
| `sirven phone log` | Everything the agent did on the phone, in plain words. `--json` for the raw lines. |

With no open session, every action is refused before anything reaches the phone. The phone
stays visible and usable the whole time: sirven does not lock it, hide its screen, or take it
over, and you can stop the agent by unplugging it.

Things the agent never does, enforced in code, not just in instructions:

- **Type into a password field.** If the focused field is a secure text field, typing is
  refused and the text is not logged. Passwords, codes, and face recognition stay with you.
- **Unlock the phone.** A locked phone returns `phone_locked`; you unlock it.
- **Spend money or commit a booking without you.** See "Money holds".
- **Act without a reason.** Every action carries a `reason` in plain words, which goes in the log.

## Money holds

A tap on something labeled like a commitment (Book, Request, Confirm, Pay, Purchase, Buy, Order,
Checkout, Subscribe, Reserve, Tip, and similar) is **held**: nothing reaches the phone, and the
agent gets `held_for_approval` with a hold token. The agent can also mark any action as money
bearing with `"money": true`. You approve with `sirven phone approve HOLD`, and the agent then
repeats the same tap with `"approval": "HOLD"`.

The label match is a heuristic, which is why holds are one part of the approval story and not
all of it: the agent's own instructions still require asking before any real-world action in
the Solo tier. When the consent moment from the tier dial thread lands, `approve` should become
one of its surfaces rather than a separate command.

## The local interface

Base URL: `http://127.0.0.1:47817/v1/phone` (`sirven phone serve --port N` to change it).
It binds to loopback only. Every request needs `Authorization: Bearer TOKEN`, where the token is
in `~/.sirven/phone/token` (mode 0600, a new token on every `serve`, deleted when it stops).
How the token reaches your agent depends on your setup: an agent running as you reads the file;
for the separate service user, hand it over the way you hand over any other key.

| Route | Body | Does |
|---|---|---|
| `GET /status` | | phone found and trusted, session open or not, WebDriverAgent ready, phone locked |
| `GET /screen?reason=...&image=0` | | the foreground app, screen size, labeled elements with frames in points, and a screenshot (a base64 encoded image) unless `image=0` |
| `POST /tap` | `{"label": "Choose pickup", "reason": "..."}` or `{"x": 195, "y": 225, "reason": "..."}`, optional `"money": true`, `"approval": "HOLD"` | taps the centre of the labeled element, or the point |
| `POST /type` | `{"text": "...", "submit": false, "reason": "..."}` | types into the focused field |
| `POST /swipe` | `{"from_x", "from_y", "to_x", "to_y", "reason"}` | a quick drag |
| `POST /home` | `{"reason": "..."}` | the home screen |
| `POST /launch` | `{"bundle": "com.example.app", "reason": "..."}` | opens an app by its bundle name |

Every answer is JSON with `result` and `said` (a plain sentence). Results:

| result | HTTP | Meaning |
|---|---|---|
| `ok`, `done` | 200 | it worked; `said` is what the log says |
| `unauthorized` | 401 | missing or wrong token |
| `no_consent` | 403 | no open phone session |
| `secure_field`, `submit_not_allowed`, `not_approved` | 403 | refused, see above |
| `held_for_approval` | 409 | waiting for the owner; carries `hold` |
| `phone_locked`, `no_phone`, `not_trusted`, `several_phones` | 409 | the phone is not in a state to drive |
| `not_found` | 404 | no element with that label on screen |
| `bad_request` | 400 | malformed body, or no `reason` |
| `no_usb_service`, `webdriveragent_not_running` | 503 | the Mac or the phone side is not up |
| `webdriveragent_error` | 502 | WebDriverAgent refused the command; `said` quotes it |

A blocked or failed action is always reported as itself. The bridge never retries an action on
its own, and never replays a tap that may have half happened: the agent reads the screen again.

## The log

`~/.sirven/phone/actions.jsonl`, appended, mode 0600, one JSON object per line:
`time`, `event` (allow, stop, screen, tap, type, swipe, home, launch, approve, deny), `session`,
`said`, `outcome` (done, held, refused, not_found), and where they apply `app`, `reason`, `hold`.
Screenshots are never written to disk. `sirven phone log` prints it like this:

```
14:02  the owner opened a phone session for 15 minutes
14:02  read the screen in com.example.rides, because: see the ride options
14:03  tapped "Choose pickup" in com.example.rides, because: set the pickup to home
14:03  wanted to tap "Request ride" in com.example.rides, which could spend money or commit a booking; held for the owner, because: book the ride [held]
```

This log is separate from the install audit log (`lib/audit.sh`): it lives in your home folder
because phone control runs as you, against your phone.

## Relation to the runtime interface

The runtime thread defines `docs/runtime-interface.md`, the local interface the policy engine,
tier dial, and usage meter plug into. That document was not in the repository when this was
written, so this interface follows the pattern its brief describes (local, authenticated,
plainly logged) and stands on its own. When it lands, reconcile: same port family and token
handling, and `/v1/phone` mounted under the runtime's interface or beside it.

## Seam for the ride concierge (threads 08 and 13)

The first use case is booking flows in apps with no public interface. For rides, the phone path
is a third way to fulfil a booking, next to an official partner backend and the human concierge:
your agent books the ride in your own ride app on your own phone.

**For the ride connector contract (thread 08).** The phone path sits *behind* the contract as a
backend. The calling agent never learns that a phone was involved; the provider is only a
returned attribute value, as the contract requires.

| Contract call | Phone backend does |
|---|---|
| `quote_ride` | `launch` the ride app, `type` origin and destination, `screen` to read each option's price, estimated arrival, and trip time, then return them as ranked options. Read-only apart from typing; no hold fires. |
| `book_ride(quote_id)` | `tap` the request button. The money hold fires, so the backend returns a result meaning "waiting for the owner's approval" with a way to poll; after `approve`, it repeats the tap with the approval and reads the confirmation screen for the booking identifier and tracking. |
| `cancel_ride(booking_id)` | `launch`, find the trip, `tap` cancel (also held when the label reads like a charge, such as a cancellation fee), read the outcome. |

Open questions for thread 08, to settle in the contract, not here:
- an error or status for "waiting for the owner's approval", which every backend that charges
  money may need;
- an error for "backend unavailable" (phone unplugged, locked, no session open), distinct from
  "no rides available";
- how a quote that was read off a screen expires, since the app's price can change between quote
  and book. The phone backend should re-read the price before tapping and refuse if it rose above
  the quoted amount or the budget ceiling.

**For the end-to-end demo (thread 13).** The phone path is an alternative to the human concierge
leg for the Waymo booking, for a user whose phone is plugged in with the Waymo app signed in.

- If the phone is not available, the orchestrator says so to the user and offers the human
  concierge. It never switches paths silently.
- Payment goes through whatever payment method is saved in the user's own ride app. The
  per-booking virtual card from thread 11 applies only if the user adds it to the app, which this
  integration does not do.
- The demo stays rehearsal only: no real booking until Jose runs it himself. Against the fake
  phone in `tests/lib/fake_phone.py` the whole quote, hold, approve, and tap sequence runs today.

## What is verified

- Verified on a Mac with no phone attached: `sirven phone detect` reaches the real USB
  multiplexer and honestly reports that no iPhone is plugged in.
- Verified against a fake phone (`tests/unit/test_phone.sh`): detection of trusted, untrusted,
  missing, and several phones; consent; reading the screen; tapping by label and by point;
  typing; swiping; launching; money holds with approve and deny; password field and return
  refusals; locked phone; session expiry and stop; the plain-language log.
- **Not yet verified against a real iPhone.** To do it: plug in and trust a phone, run the setup
  plan, then `sirven phone status`, `sirven phone allow`, `sirven phone serve`, and from another
  terminal `GET /screen` and a `POST /tap` on something harmless, then `sirven phone log`.

## Credit

The approach, and the WebDriverAgent routes this uses, come from
[iPhone-use](https://github.com/zhongerxin/iPhone-use) by ZHONG XIN, under the MIT license.
sirven's integration layer is its own code; no iPhone-use code is copied. WebDriverAgent is from
the Appium project, under the BSD license, and is fetched by you at setup time, not bundled.
