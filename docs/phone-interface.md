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
  phone and accepts commands over HTTP. At run time no full Xcode is open. Two light processes
  start it: `pymobiledevice3 remote start-tunnel --native` makes the tunnel to the phone, and
  `pymobiledevice3 developer dvt xcuitest` launches the runner through that tunnel. `sirven phone
  start` runs both and restarts whichever one stops. sirven reaches the runner through the USB
  multiplexer directly, so no separate port forwarder is needed. `SIRVEN_WEBDRIVERAGENT_URL` points sirven at a
  forwarder you already run instead, and is refused unless it is loopback HTTP.
- **No analytics.** sirven sends nothing anywhere. (iPhone-use itself ships anonymous
  analytics that are on by default; none of that code is here.)

## Setup, once

`sirven phone setup --team TEAM --bundle BUNDLE` prints the plan. sirven never runs it for you,
because it signs software with your Apple account.

1. On the phone: plug it in, unlock it, tap Trust.
2. On the phone: Settings > Privacy & Security > Developer Mode, on, then restart.
3. On the Mac: install the pymobiledevice3 tool once with the Python tool installer, uv (needs
   Python 3.12 or newer, and no administrator password): `uv tool install pymobiledevice3==11.28.2`.
4. On the Mac: sign and install the runner once, with ONE of the two routes below, not both.
   - **Route A, EXPERIMENTAL and not yet proven on a real phone.** xtool, a command-line tool,
     signs the runner with your Apple account and installs it. Install it with
     `brew install xtool-org/tap/xtool` (its app may ask to move into your Applications folder;
     allow it). Download the pinned runner, `WebDriverAgentRunner-Runner.zip` from the v16.14.0
     release, and check it:

     ```
     mkdir -p ~/.sirven/WebDriverAgent && curl -fL -o ~/.sirven/WebDriverAgent/runner.zip https://github.com/appium/WebDriverAgent/releases/download/v16.14.0/WebDriverAgentRunner-Runner.zip && echo '6f7758f72d348d2c35c3fd134fa76a941bba0c447de04b2e9d065682f31fc47f  ~/.sirven/WebDriverAgent/runner.zip' | shasum -a 256 -c - && unzip -o ~/.sirven/WebDriverAgent/runner.zip -d ~/.sirven/WebDriverAgent
     ```

     If shasum reports FAILED, the download is not the release: stop. Nothing is unzipped.
     Then `xtool auth login` (xtool asks for your Apple account sign-in; sirven never sees it), and
     `xtool install ~/.sirven/WebDriverAgent/WebDriverAgentRunner-Runner.app`. Known limits: a
     free Apple account signs for 7 days at a time, xtool uses Apple interfaces that are not
     public, and whether the test bundle inside the runner signs correctly is not verified yet.
     The evidence is in `docs/research/xtool-lighter-phone-path.md`.
   - **Route B, the fallback: full Xcode.** Used only for this step, never at run time. It builds
     WebDriverAgent from source at the commit iPhone-use pins, and does not use the download above.
     Clone it into `~/.sirven/WebDriverAgent-source`, then run `xcodebuild ... test` there with
     your own development team and a bundle name you own, and press Ctrl-C once the test starts on
     the phone.
5. On the phone, the first time: trust your developer certificate (Settings > General, the device
   management page), and turn on the user interface automation switch under Settings > Developer.
6. Run `SIRVEN_PHONE_RUNNER_BUNDLE=BUNDLE.xctrunner sirven phone start` and leave it running.
   The runner identifier is the bundle name you gave setup, with `.xctrunner` added.
7. From another terminal, `sirven phone status`.

| Command | What it does |
|---|---|
| `SIRVEN_PHONE_RUNNER_BUNDLE=BUNDLE.xctrunner sirven phone start` | Starts the tunnel and the launcher and keeps both running. When one stops it is started again after 1 second, then 2, 4, and so on up to 30 seconds; a process that stays up for a minute starts over from 1 second. When the tunnel stops, or the launcher fails three times in a row without staying up, both start again with the tunnel's new address. A stopped process's last lines are printed. Ctrl-C or closing the terminal stops both. A second start is refused while one is running, and leftover processes from an earlier run block a new start until you stop them. |
| `sirven phone status` | Also says whether the tunnel and the launcher are running, or not running. |

## Consent: opt in per session, owner only

Phone control is off until you turn it on, at a terminal, by typing yes:

| Command | What it does |
|---|---|
| `sirven phone allow [--minutes N]` | Open a phone session, 30 minutes by default, at most 240. |
| `sirven phone allow --allow-submit` | The same, and the agent may press return. Without it, any text with a newline, or a submit, is refused, because a return can send a message or a form. |
| `sirven phone stop` | End the session now. The next agent request is refused. |
| `sirven phone holds` | Actions waiting for your approval. |
| `sirven phone approve HOLD` / `deny HOLD` | Decide one held action. An approval is good once, for that exact action, for five minutes. |
| `sirven phone log` | Everything the agent did on the phone, in plain words. `--json` for the raw lines. |

**Where this holds, and where it does not.** The session file and the hold approvals live in
your own state folder (`~/.sirven/phone`, mode 0700). When your agent runs as the separate
service user (`agent` by default), it cannot write there, so it cannot open its own session or
approve its own holds: the checks below are load-bearing. When your agent runs as you, under
your own account, it could write those files itself, and the checks become guardrails that keep
an honest agent honest, not a wall. Run the agent as the service user if you want the wall.
(The test seam, a typed yes skipped against a fake phone, writes records stamped test only that
are never honoured once the real USB multiplexer is in use.)

With no open session, every action is refused before anything reaches the phone. The phone
stays visible and usable the whole time: sirven does not lock it, hide its screen, or take it
over, and you can stop the agent by unplugging it.

Things the bridge refuses in code, not just in the agent's instructions:

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

Every labeled element under the tap point counts, so a tap on a price inside a "Request ride"
button is still held. When the screen's elements cannot be read at all, the tap is refused
rather than made blind. Swipes are not gated, so a slide-to-pay control is not caught.

The label match is a heuristic, which is why holds are one part of the approval story and not
all of it: the agent's own instructions still require asking before any real-world action in
the Solo tier. When the consent moment from the tier dial thread lands, `approve` should become
one of its surfaces rather than a separate command.

## The phone's own payment approval

When a purchase reaches checkout, the phone shows its own face recognition or Apple Pay prompt
for that one purchase. Only you answer it, on the phone. While it is on screen the bridge
refuses every tap, keystroke, and swipe with `owner_approving_on_phone`, and `GET /screen`
reports `"owner_approving_on_phone": true`, so the agent waits and reads the screen again.
sirven never presses that prompt, never stores or replays a scan, and never lets one approval
cover a later purchase. Together with the money hold, every payment is two live approvals for
that one purchase: `sirven phone approve`, then the prompt on the phone.

## Onboarding: the semantic map

The first time you connect the phone each day, `sirven phone allow` offers onboarding, and
`sirven phone onboard` runs it after your typed yes. It lists the apps on your home screens by
name, then walks the screens of the apps you choose (`--app NAME`, repeatable; Uber and Lyft by
default) and writes a semantic map to `~/.sirven/phone/map.json`: which app, which screen,
where each key control is, what it does (its role, such as `destination_field` or
`request_button`), and which screen it leads to. The agent reads it with `GET /map`, so it knows
where to look instead of rediscovering each screen.

What the crawl never does, in code: type, tap by point, or tap anything that could spend money,
commit, send, delete, or sign out. It stops at once if the phone shows its own payment approval.
To reach a deeper screen it relaunches the app fresh (`"fresh": true` on `POST /launch` closes
the app first) and replays the taps.

What the map never stores: a screenshot, any field's value, static text (where personal content
lives), list rows without a price, or anything from a login screen (only a count of login
screens skipped). A priced row is kept only as its shape, digits replaced by `#`
("UberX, # min away, # min trip, $#.#"). Labels over 40 characters, or with an `@`, are dropped.

| Command | What it does |
|---|---|
| `sirven phone onboard [--app NAME]... [--refresh]` | Build the map, or rebuild those apps with `--refresh`. Opens a short session for the crawl when none is open, and closes only that one. |
| `sirven phone map [--json]` | See the map in plain lines, or the raw JSON. |
| `sirven phone map prune APP [SCREEN]` | Remove an app, or one screen, from the map. |

The owner's words for this moment are in `copy/phone-onboarding.md`.

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
| `POST /launch` | `{"bundle": "com.example.app", "reason": "...", "fresh": false}` | opens an app by its bundle name; `fresh` closes it first so it starts from its first screen |
| `GET /map` or `GET /map?app=BUNDLE` | | the semantic map, needs an open session |
| `GET /holds/HOLD` | | the state of one hold: waiting, approved, denied, or used. Read only |

Every answer is JSON with `result` and `said` (a plain sentence). Results:

| result | HTTP | Meaning |
|---|---|---|
| `ok`, `done` | 200 | it worked; `said` is what the log says |
| `unauthorized` | 401 | missing or wrong token |
| `no_consent` | 403 | no open phone session |
| `secure_field`, `submit_not_allowed`, `not_approved` | 403 | refused, see above |
| `held_for_approval` | 409 | waiting for the owner; carries `hold` |
| `owner_approving_on_phone` | 409 | the phone is showing its own payment approval; touch nothing, read again |
| `phone_locked`, `no_phone`, `not_trusted`, `several_phones`, `screen_unreadable` | 409 | the phone is not in a state to drive |
| `not_found` | 404 | no element with that label on screen |
| `bad_request` | 400 | malformed body, or no `reason` |
| `no_usb_service`, `webdriveragent_not_running` | 503 | the Mac or the phone side is not up |
| `webdriveragent_error` | 502 | WebDriverAgent refused the command; `said` quotes it |

A blocked or failed action is always reported as itself. The bridge never retries an action on
its own, and never replays a tap that may have half happened: the agent reads the screen again.

## The log

`~/.sirven/phone/actions.jsonl`, appended, mode 0600, one JSON object per line:
`time`, `event` (allow, stop, screen, tap, type, swipe, home, launch, approve, deny), `session`,
`said`, `outcome` (done, held, refused, not_found, failed: an action that errored after it may
have reached the phone is still logged), and where they apply `app`, `reason`, `hold`.
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

## The iPhone ride backend

The first use case, booking flows in apps with no public interface, is built:
`connectors/ride/ride_phone` implements the ride connector's backend interface by driving the
owner's own Uber or Lyft app through this interface. It finds the app and its destination field
in the semantic map, reads the priced rows, re-reads the price before booking and refuses if it
rose, taps the request button (held for `sirven phone approve`), then waits, touching nothing,
while the owner answers the phone's own payment prompt. The calling agent never learns that a
phone was involved; the provider is only a returned value. See `connectors/ride/README.md` and
the contract's "What the payment approval reads".

Open for Jose: the phone's own prompt appears only when the ride app pays with Apple Pay; with a
saved card the money hold is the only approval. Whether sirven should refuse to book in that
case is his decision.

## What is verified

- Verified on a Mac with no phone attached: `sirven phone detect` reaches the real USB
  multiplexer and honestly reports that no iPhone is plugged in.
- Verified against a fake phone (`tests/unit/test_phone.sh`): detection of trusted, untrusted,
  missing, and several phones; consent; reading the screen; tapping by label and by point;
  typing; swiping; launching; money holds with approve and deny, including a price nested
  inside a request button; an unreadable screen; password field and return refusals; locked
  phone; session expiry and stop; failed actions in the log; the test seam never honoured for
  a real phone; the plain-language log.
- Verified against the fake phone in world mode (`tests/unit/test_phone_map.sh`,
  `tests/phone/`): onboarding, the map's privacy rules, prune, the once-a-day offer, and the map
  route; and (`tests/unit/test_phone_ride.sh`) quoting and booking a ride with both live
  approvals, a refused hold, a decline on the phone, a price that rose, cancelling, and the
  payment prompt never touched.
- Verified with fake processes only (`tests/unit/test_phone_runner.sh`, `tests/phone/`): the
  supervisor starts the tunnel and the launcher, reads the tunnel's address from its output,
  restarts the launcher with a new address after the tunnel restarts, waits longer after each
  failure up to the cap, and stops both cleanly; `sirven phone status` reads the runner file.
- **Not yet verified against a real iPhone.** The real tunnel, the real runner, and the xtool route
  have not run on hardware. To do it: plug in and trust a phone, run the setup plan, then
  `sirven phone start` in one terminal, `sirven phone status`, `sirven phone allow`,
  `sirven phone serve`, and from another terminal `GET /screen` and a `POST /tap` on something
  harmless, then `sirven phone log`.

## Credit

The approach, and the WebDriverAgent routes this uses, come from
[iPhone-use](https://github.com/zhongerxin/iPhone-use) by ZHONG XIN, under the MIT license.
sirven's integration layer is its own code; no iPhone-use code is copied. WebDriverAgent is from
the Appium project, under the BSD (Berkeley Software Distribution) license, and is fetched by you at setup time, not bundled.
