# Concierge trust and safety protocol

Binding on every concierge, on Jose as the on-call lead, and on the software around them. This
protocol is one of the three things the ship gate requires before the human-concierge tier
ships:

> "Do not ship the human-concierge tier until the service-level targets, the concierge trust
> and safety protocol, and the user-facing disclosure of concierge involvement are all in place."

Draft for Jose's review. Items marked **Jose decides** are collected in [README.md](README.md).

## 1. Why sirven does this, said plainly

Personal agents act for people. Sellers have built a stack (dark patterns, surge framing,
interfaces that only open for a human thumb on a phone) that works against the person buying.
Some services, Waymo first among them in San Francisco, offer no way for a person's own agent
to book on their behalf. People with an assistant have always had someone book their car for
them. A sirven concierge extends that ordinary practice to everyone else.

That is a justice argument, and sirven makes it openly. It is not a hidden workaround of a
service's terms. The difference shows up in conduct:

- **No false identities.** Every service account is in a real person's real name.
- **No evasion.** No spoofed locations, no device tricks, no fresh accounts after a suspension.
- **No lies.** If a service asks who is booking or who is riding, the concierge answers
  truthfully or stops and hands back. They never invent an answer.
- **If a service objects, sirven stops and says so.** The concierge layer for that service
  pauses, users are told plainly why, and the disagreement is argued in the open rather than
  routed around. **Jose decides** whether this commitment is published as written.

Concierges should be able to explain this section in their own words. It is the reason the
job exists, and it is why the rules below are strict.

## 2. Consent and disclosure

**The user consents before a human sees anything.** A trip request reaches the concierge queue
only when the user has agreed, in words they actually saw, that a person will see the trip they
asked for. The queue tool refuses any request without that consent recorded
(`concierge_queue.py submit --consent disclosed`), and the refusal is tested.

**The user knows who.** When a concierge claims a request, the user is told a person is booking
their ride and sees the concierge's display name (first name and last initial, "sirven
concierge"). The concierge never hides behind a generic name.

**The user can withdraw.** Withdrawing consent mid-request closes it with handback reason
`consent_withdrawn`; the concierge stops immediately and the trip details leave the console.

**Positioning.** Jose's decision: the concierge layer is a back-end detail, not a led-with
feature. Copy treats it as infrastructure and discloses it plainly where it operates (at
consent, at claim, on the booking confirmation), never as a marketing headline and never
buried.

**Disclosure copy is owned elsewhere.** The user-facing disclosure is the third ship-gate item
and is not this deliverable. What it must contain, at minimum:
1. That a person, not software, books this ride.
2. What that person sees (section 3) and what they never see.
3. The concierge's display name, once claimed.
4. That the ride is booked on an account sirven controls, not the user's own.
5. How to withdraw, and what happens to the trip details afterwards (section 4).

## 3. What a concierge may see, and what they must never do

**May see, only for a request they have claimed:**
- Pickup and drop-off locations, and the departure window.
- The budget ceiling and any preference the user set for this trip (for example "Waymo
  preferred").
- The rider's first name, only if the service needs it to match rider and car.

**Never sees:** the user's full name, phone number, email, payment card, calendar, the
reason for the trip, or anything else the agent knows. The console shows only the fields above.

**Must never:**
1. Book without the user's acceptance of the exact quote, or above the budget ceiling.
2. Contact a user outside the console, share their own contact details, or meet a user.
3. Copy, screenshot, photograph, write down, or repeat any trip detail, during or after work.
4. Use a trip detail for anything but that booking.
5. Use a personal account, or a personal payment card, for a sirven booking.
6. Lie to a service: about who is booking, who is riding, or why.
7. Use any evasion technique (section 1), or try again on another account after a refusal.
8. Book for a rider who appears to be a minor.
9. Accept money, tips, or gifts from a user.
10. Discuss any user or trip with anyone except the on-call lead, for escalation.

Breaking rule 3, 6, or 7 ends the engagement. Others are reviewed case by case.

## 4. Data rules

- **The queue log holds no trip content.** Timings, outcomes, amounts, and the concierge's
  roster key only; the test `test_the_log_holds_no_trip_content` pins the field list.
- **Trip details live in the console only while the request is open**, and are dropped when
  it closes (booked or handed back). **Jose decides** whether a short retention (for example 24
  hours, for disputes and refunds) is needed; the recommendation is none beyond what the
  service itself keeps in the account's ride history.
- **The service account's own ride history** is the one copy that persists outside sirven's
  control. It sits on sirven-controlled accounts (hiring packet, section 6, option 2) so that
  sirven, not the concierge personally, is its custodian.
- **Concierges work on a device with a screen lock**, and close the console when off shift.

## 5. Escalation

Three levels. The on-call lead is Jose during launch unless he names someone else.

**Urgent: act now, tell the on-call lead within 5 minutes.**
- Any safety issue on a ride a concierge booked: the service's support contacts the concierge
  as account holder, the rider reports a problem, or the car stops somewhere unsafe. The
  concierge relays to the rider at once through the console, tells the rider to use the
  in-car support button, and to call 911 for any emergency.
- A service asks who is riding or booking and the concierge cannot answer truthfully without
  stopping: stop, hand back with reason `safety` or `other`, tell the on-call lead.
- Any suspected data exposure (a lost device, a wrong recipient).

**Same day.**
- A booking that went wrong without a safety issue (wrong pickup, charged twice).
- A service account warning, limit, or suspension notice. The account is paused; no new
  account is opened to replace it (section 1).
- A user complaint about a concierge.

**Weekly review.**
- Service-level breaches and handbacks from the weekly report ([monitoring.md](monitoring.md)).
- Patterns: the same pickup failing, the same hour always slow.

Every urgent or same-day issue gets a short written note: what happened, what was done, what
changes. Notes name no user and quote no trip detail.

## 6. Offboarding

Same day as the decision, in this order:

1. Set the concierge's roster status to `offboarded`. The queue tool refuses their claims from
   that moment; the test `test_offboarded_concierge_cannot_claim` pins this.
2. Revoke console access and end all signed-in sessions.
3. Service account: change the password, sign out all devices, remove the payment card, and
   move two-step verification to sirven. For option 3 accounts (personal), ask the concierge
   to remove the sirven card in front of Jose.
4. Remove from the on-call contact list.
5. Ask the concierge to confirm in writing that they keep no trip details in any form, and
   remind them the confidentiality agreement survives the engagement.
6. Final pay on time. California requires final wages immediately on dismissal, and within 72
   hours on a resignation without notice; confirm with the payroll provider.
7. Note the offboarding in the roster history (date and reason category, no detail).

If the offboarding follows a breach of rule 3, 6, or 7 in section 3, Jose also decides whether
affected users are told.
