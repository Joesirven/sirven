# Concierge disclosure: every word the user sees about the concierge

status: draft for Jose's review

This file is the user-facing disclosure of concierge involvement, one of the three items the
ship gate requires before the human-concierge tier ships. The demo reads its words from here,
so Jose's review is one read and the run can never drift from what he approved. The gate
check passes this item only when the status line above reads `status: approved`.

Positioning (Jose, October 11, 2026): the concierge layer is a back-end detail, not a feature
the product leads with. These words appear only where a concierge actually operates, and they
say so plainly.

Placeholders in braces are filled in by the agent at run time.

## consent-before-quote

Waymo rides are booked for you by a person on the sirven team (a concierge). To get a price
and book, they will see your pickup ({origin}), where you are going ({destination}), and when
({window}). They will not see your calendar or anything else about you. If you book, they also
see the most you agreed to pay, and they book nothing above it. Is that all right?

## declined-consent

Understood. No one will see this trip. I will only show options I can book without a person.

## consent-before-booking

Book {product} for {price}? Pickup about {pickup} at {origin}, arriving about {arrival}.
Nothing above {cap} is booked. {booked_by_line}

## booked-by-concierge-line

A sirven concierge books this one in the Waymo app for you, and I will tell you who.

## booked-by-concierge

Booked by {concierge}, a sirven concierge. Confirmation {confirmation}.

## seen-by-concierge

{concierge}, a sirven concierge, saw this trip request.

## queued-unclaimed

This trip request reached the concierge queue, but no concierge took it.

## waymo-unavailable

I could not get a Waymo price in time ({reason}). I am not going to keep trying behind your back.
Here is what I can book instead.
