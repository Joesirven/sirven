# Concierge hiring packet: San Francisco, first two or three hires

Prepared for Jose, who makes every hiring decision (decision of October 11, 2026). Nothing in
this packet has been posted, sent, or acted on. No accounts exist. Every item marked
**Jose decides** is listed again in [README.md](README.md).

## 1. Role description (draft, held for Jose's review)

**Title:** Ride concierge, San Francisco (part time)

**What the work is.** A sirven user's personal agent asks for a ride. When the best ride is
one the agent cannot book on its own (Waymo is the main case), the request comes to you. You
see the trip the user asked for, quote it in the service's app, and book it once the user
accepts. Most requests take two or three minutes of attention. You work from a phone or a
laptop during scheduled shifts.

**What matters most.**
- Speed you can keep up: a quote back within 30 seconds of the request, a confirmed booking
  within 90 seconds of the user saying yes.
- Discretion. You see where people are going. You never keep it, share it, or use it.
- Honesty under pressure. When a ride cannot be booked, you say so plainly and hand it back;
  you never improvise around a rule to make it work.
- Calm escalation when something goes wrong on a ride you booked.

**What you will not do.** Drive anyone, ride along, meet users, or contact a user outside the
sirven console.

**Hours and pay.** Scheduled shifts inside the coverage window in section 5. Pay follows the
model Jose picks from [pay-model.md](pay-model.md).

**Where.** Remote, but you must live in the San Francisco Bay Area: you need local knowledge
(neighborhoods, pickup spots, event traffic) and you may need to test a pickup point in person
during onboarding.

**Your identity is shared with riders.** Users are told a person is handling their booking and
see your first name and last initial. Candidates must be comfortable with that before applying.

## 2. Screening criteria

Score each candidate 1 to 3 on each line. A 1 on any line marked *required* ends the process.

| Criterion | What a 3 looks like | Required |
| --- | --- | --- |
| Timed accuracy | Passes the work sample (section 3) inside both targets with no booking errors | yes |
| Discretion | Gives concrete examples of handling other people's private information; no oversharing in the interview itself | yes |
| Honest handback | In the scenario questions, hands back rather than bending a rule | yes |
| Rideshare and San Francisco fluency | Daily or weekly Waymo or rideshare user; knows pickup quirks of busy areas | no |
| Shift reliability | Can commit to a fixed weekly schedule for at least three months | yes |
| Written clarity | Short, plain messages; no jargon | no |
| Calm escalation | Scenario answer routes a safety issue to the rider and to the on-call lead within minutes | yes |

**Scenario questions** (spoken, about ten minutes):
1. The user accepted a $22 quote; the price in the app is now $27 and their ceiling is $25.
   What do you do? (Good answer: do not book; hand back with `over_budget` so the agent can ask
   the user again.)
2. The service's app asks you to confirm you are the rider. What do you do? (Good answer: do
   not lie. Stop, hand back, escalate to the on-call lead. See the trust and safety protocol,
   section 3.)
3. Waymo support calls you mid-ride about a problem with the car. What do you do?
4. A user messages you through the console asking for your phone number "in case". What do you
   say?

## 3. Work sample (paid, about 45 minutes)

A timed run on the rehearsal console, using the queue tool in
[tools/concierge_queue.py](tools/concierge_queue.py) with a scratch log and fake requests. No
real service account, no real booking. The candidate works five requests: three normal, one
over budget, one where the request arrives without recorded consent (the tool refuses it; the
candidate should notice and not try to work around it). Score with `concierge_queue.py report`
over the scratch log.

Pay the work sample at the hourly rate in the chosen pay model. Unpaid trial work is a legal
risk under California wage law and a bad first impression either way.

## 4. Onboarding checklist

Done in order. Each line is checked off by Jose or by the concierge with Jose confirming.

**Before day one**
- [ ] Offer accepted in writing; worker classification settled (see [pay-model.md](pay-model.md), section 4).
- [ ] Background check, if Jose wants one, run only after a conditional offer, as California's
      Fair Chance Act and the San Francisco Fair Chance Ordinance require.
- [ ] Payroll and tax forms through the payroll provider.
- [ ] Confidentiality agreement signed, including the data rules in the trust and safety protocol, section 4.
- [ ] Display name agreed (first name and last initial) for disclosure to users.

**Day one: access**
- [ ] Concierge added to the roster with status `active` (format: [tools/roster.example.json](tools/roster.example.json)).
- [ ] Console access issued under the concierge's own sign-in, with two-step verification on.
- [ ] Service account provisioned per the runbook in section 6.
- [ ] Added to the on-call contact list for escalations.

**Day one: training (about three hours, paid)**
- [ ] Read the trust and safety protocol end to end; walk through it with Jose.
- [ ] Read the justice framing (trust and safety protocol, section 1) and talk it through: why
      sirven does this in the open, and what that means when a service pushes back.
- [ ] Ten rehearsal requests on the console with a scratch log, including two handbacks and one
      safety escalation drill.
- [ ] One supervised live request with Jose watching, once the tier is cleared to ship.

**First two weeks**
- [ ] Weekly service-level report reviewed together (see [monitoring.md](monitoring.md)).
- [ ] Any breach or handback reviewed without blame: what slowed it, what would fix it.
- [ ] End of week two: Jose confirms the concierge stays on the roster.

## 5. Scheduling coverage proposal

The service-level targets only hold while someone is on shift. Outside covered hours the agent
tells the user plainly that a concierge-booked ride is not available right now and offers what
the other backends can do. It never quietly queues a request no one will see.

**Option A, narrow launch window (recommended for the first month): 43 hours a week.**

| Day | Covered hours (Pacific time) | Hours |
| --- | --- | --- |
| Monday to Friday | 7:00 to 10:00 and 16:00 to 20:00 | 35 |
| Saturday | 10:00 to 18:00 | 8 |

Two concierges split this at about 21 hours each. The commute peaks are when ride requests
cluster, and the narrow window keeps cost low while the volume is unknown.

**Option B, wide window: 105 hours a week.** Every day, 7:00 to 22:00. Needs three concierges at
about 35 hours each, with no slack for illness.

**Single coverage is the main risk.** With one concierge on shift, two requests arriving
together means the second waits. At low volume this is rare, but the `unclaimed` warning in
[monitoring.md](monitoring.md) fires at 10 seconds, and someone has to be able to pick it up.
**Jose decides** who the second line is during launch: Jose himself, or a paid on-call backup
shift.

**Absences.** Concierges swap shifts among themselves and tell Jose by message at least 24 hours
ahead. A shift no one can cover is closed in advance, so the agent tells users honestly, rather
than staffed by hope.

## 6. Account-provisioning runbook

This is the most uncertain part of the plan. Three options, each with what to verify first.
**Jose decides** which one; nothing is created until he does.

**Before any option: verify the service's rules.** Read Waymo's current rider terms and
community guidelines and record the answers to:
1. May an account holder book a ride for someone else who rides alone?
2. How does a rider who is not the account holder unlock and board the car? (If the car can
   only be unlocked from the account holder's phone, the concierge must unlock it remotely or
   the user cannot get in. This has to be tested in a rehearsal ride Jose takes himself.)
3. Does Waymo offer a business or organization account in San Francisco, and on what terms?
4. Minimum rider age and rules for minors (concierges never book for a minor).

These answers decide whether this layer is the open, defensible practice the trust and safety
protocol describes, or something that needs a direct conversation with Waymo first.

**Option 1: a sirven business account with the service, if one exists.** Cleanest. sirven is the
account holder; each concierge is a named user under it; payment is sirven's. Verify the terms
allow booking for non-employee riders.

**Option 2: sirven-controlled individual accounts, one per concierge (recommended if option 1
does not exist).** Each account is opened in the concierge's real name (never a false
identity), with a sirven-issued payment card (the per-booking card from the money-layer thread
when it is ready, a test-mode card until then), a sirven-managed email address, and two-step
verification on a device sirven controls or the concierge's phone. sirven can lock and recover
the account at offboarding. The concierge's personal ride history never mixes with work.

**Option 3: concierges' personal accounts, reimbursed.** Fastest to start, worst to end: sirven
cannot revoke access at offboarding, users' trips land in the concierge's personal history, and
reimbursement adds accounting work. Not recommended beyond a rehearsal.

**Provisioning steps for option 2** (run by Jose or with Jose present, after his approval):
1. Create the sirven-managed email address for the concierge.
2. Open the service account in the concierge's real name with that address.
3. Attach the sirven payment card. Confirm no personal card is on file.
4. Turn on two-step verification. Record the recovery method in sirven's password manager,
   never in a document or message.
5. Add the account to the roster entry (by reference, not by password).
6. Book one rehearsal ride with Jose as the rider to confirm boarding works end to end.

**Deprovisioning** is part of offboarding: trust and safety protocol, section 6.
