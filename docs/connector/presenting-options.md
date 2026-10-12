# presenting ride options to a person

This page is for a personal agent, or the developer building one, that has called `quote_ride` and now has to show the result to the person it works for. The calls themselves are in [calling-the-connector.md](calling-the-connector.md). This page is about the conversation around them.

## the order is the connector's, the choice is the person's

`quote_ride` returns `options` already ranked (`rank` 1 is best) against the preferences and budget ceiling you sent, with every bookable option ahead of every unbookable one. Show them in that order. Do not re-rank by your own idea of what the person wants, and do not drop options silently. If you leave some out to keep the message short, say how many and why ("three more, all over your limit").

Lead with the top option, then two or three more at most. A good shape:

> The best match is a Waymo, 10.73 dollars, picks up around 3:00, arrives around 3:11.
> Also available: a Lyft at 9.51 dollars, same times.
> Book the Waymo?

Every option you show carries the same four facts, in plain words: who provides it (`provider`), the price, when it picks up (`estimated_pickup_at`), and when it arrives (`estimated_dropoff_at`). Give times in the person's local time, not as a duration they have to add up.

If an option carries a constraint flag worth knowing, say it in a short clause next to that option rather than in a footnote: "over your limit once a tip is allowed for", "outside the time you asked for", "busy-time pricing", "the price is an estimate".

## prices are prices

Money in the contract is in the smallest unit of the currency: `1073` with `USD` is 10.73 dollars. Say the amount the connector returned; never round a price down.

- When `price.kind` is `fixed`, say the amount.
- When it is `estimate`, say both ends: "about 9.78 dollars, at most 12.22".
- When the person confirms, say the most they can be charged, which is `charge_terms.authorization_cap` (the fare ceiling plus the tip allowance): "up to 11.41 dollars with tip". The money layer never holds or charges more than that, so the person never hears a smaller number than what they could pay.

## ask before booking, at the tier the person chose

On the Solo tier the agent asks before every real-world action. Booking a ride is a real-world action, and so is cancelling one. Ask, and wait for an answer:

> Book the Waymo for 10.73 dollars? You can cancel free until 2:30.

On Neighborly and Co-op the person may have given the agent more room: a budget and preference rails it can act inside. Even then, tell the person what was booked, for how much, and until when they can cancel for free, right after it happens. Acting inside the rails never means acting silently.

## after a booking

A booking comes back in one of two states, and they are not the same promise.

- `confirmed`: say it is booked, when it picks up, and until when cancelling is free (`cancellation_policy.free_until`). When `tracking.share_url` is not null, give that link so the person can follow the ride.

  > Booked. Lyft picks you up around 3:00. Free cancellation until 2:30.

- `requested`: say it is requested, not booked, and when you will know (`confirm_by`). Do not put it on the calendar as confirmed until `get_ride` says `confirmed`. If it fails, tell the person and offer to quote again.

  > Requested. The Waymo is not confirmed yet; I will tell you by 1:15, and I will look for another ride if it is not.

## when a ride is blocked

Sometimes no option can be offered: the ride services refused access to agents (`blocked`), nothing serves the trip (`no_service`), or nothing fits the budget ceiling. Say so plainly and say why. The error's `message` is written for a person and can be shown as is.

Do not route around a block. No retry through a different path, no other account, no invented option. The Solo tier promise is that blocking is honestly surfaced, never routed around, and that promise holds on every tier.

> I could not get you a ride: the ride services for this trip refuse requests from agents, and I do not work around that. You can still book it yourself in the ride service's own app.

When nothing fits the budget, offer the person a real next step and let them pick:

> Nothing fits 10 dollars for that window. The cheapest is a Waymo at 10.73. Do you want to raise the limit, leave later, or skip it?

## when a person helps behind the scenes

Some options are carried out by a person on the sirven concierge team, who books the ride on the person's behalf (in San Francisco first). These options have `fulfillment.method` set to `human_assisted` and a `fulfillment.disclosure` sentence. Today the reference connector returns:

> A person on the sirven concierge team books this ride for you.

That wording is placeholder text awaiting Jose's approval, as part of the concierge trust and safety protocol. Show whatever sentence the connector returns, exactly as returned, and never a copy of the one above.

This is part of how the service works, not a feature. Do not lead with it, and do not describe it as a selling point. Do show the disclosure sentence whenever the person is choosing that option, and before they approve the booking, not after. If the person does not want anyone to see the trip, offer the options whose `fulfillment.method` is `automated`.

Human-assisted options only appear where the human-concierge tier is turned on, which it is not in production until that tier's ship gate is met. The same quote may come back with them on one day and without them on another; present whatever the list holds.

## words to use

- Say "ride", "price", "picks up", "arrives", "cancel". Keep identifiers like `quote_id` and `booking_id` for your own calls; a person never needs to see them.
- Spell everything out. "Estimated arrival", not an abbreviation. "Model context protocol", not an abbreviation.
- Keep the tone plain and calm. A ride is a small thing; a long explanation makes it feel bigger than it is.
