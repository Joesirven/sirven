# presenting ride options to a person

This page is for a personal agent, or the developer building one, that has called `quote_ride` and now has to show the result to the person it works for. The call itself, its fields, and its errors are in the contract (see [README.md](README.md)). This page is about the conversation around the call.

## the order is the connector's, the choice is the person's

`quote_ride` returns options already ranked against the preferences and budget ceiling you sent. Show them in that order. Do not re-rank by your own idea of what the person wants, and do not drop options silently. If you want to hide an option (for example, one that breaks the budget ceiling), say that you hid it and why.

Lead with the top option, then the rest in a short list. A good shape:

> The best match is a Waymo, 19 dollars, picks you up around 3:05 and gets you there around 3:22.
> Also available: an Uber at 16 dollars arriving 3:02, and a Lyft at 21 dollars arriving 3:10.
> Book the Waymo?

Every option you show should carry the same four facts, in plain words: who provides the ride, the price, when it picks up, and when it arrives. If an option carries a constraint flag (over budget, outside the departure window, preferred provider not available), say the flag in a short clause next to that option rather than in a footnote.

## prices are prices

Say the amount and the currency the connector returned. Do not round a quoted price down. If the quote carries a tip ceiling, mention it once when the person confirms ("19 dollars, with up to 3 dollars of tip allowed"). The money layer holds the card to the quoted amount plus that ceiling; the person should never be surprised by a charge larger than what they heard.

## ask before booking, at the tier the person chose

On the Solo tier the agent asks before every real-world action. Booking a ride is a real-world action, and so is cancelling one. Ask, and wait for an answer:

> Book the Waymo for 19 dollars?

On Neighborly and Co-op the person may have given the agent more room (a budget and preference rails it can act inside). Even then, tell the person what was booked, for how much, and how long they have to cancel without a fee, right after it happens. Acting inside the rails never means acting silently.

## after a booking

Tell the person three things: that it is booked, where to follow the ride (the tracking surface the booking returned), and until when they can cancel. Put the cancellation window in their local time, not as a duration they have to compute.

> Booked. Waymo picks you up at 3:05. You can follow it here: (tracking link). Free cancellation until 2:55.

## when a ride is blocked

Sometimes no option can be offered: the site refused the request, the route is outside every provider's service area, or nothing fits the budget ceiling. Say so plainly and say why, in the words the error gave you. Do not route around a block, do not retry through a different path to get past it, and do not invent an option. The Solo tier promise is that blocking is honestly surfaced, never routed around; that promise holds on every tier.

> I could not get a ride under 25 dollars for that window. The cheapest option was 31 dollars. Do you want to raise the limit, leave later, or skip it?

Offer the person a real next step (a different budget, a different window, or doing nothing), and let them pick.

## when a person helps behind the scenes

For some providers, sirven completes the booking with a trained person (a concierge) doing the booking step on the person's behalf, in San Francisco first. This is part of how the service works, not a separate product, so do not lead with it and do not describe it as a feature. Do disclose it plainly whenever it applies to the option the person is choosing:

> The Waymo booking is completed by a sirven concierge, a person who books it on your behalf and sees only this trip request.

Say this before the person confirms, not after. If the person does not want a person to see the trip request, offer the options that do not need one. The contract tells you when an option involves a concierge; see the contract section linked from [README.md](README.md).

## words to use

- Say "ride", "price", "pickup", "arrives", "cancel". Avoid internal terms like quote identifier or booking identifier in what you show a person; keep those for your own calls.
- Spell things out. "Estimated arrival", not an abbreviation. "Model context protocol", not an abbreviation.
- Keep the tone plain and calm. A ride is a small thing; a long explanation makes it feel bigger than it is.
