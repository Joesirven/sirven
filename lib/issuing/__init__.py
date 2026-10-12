"""per-booking virtual cards through Stripe Issuing, test mode only.

the money layer for ride bookings. at booking time sirven reserves the capped amount on the
user's own card (a held payment, never captured up front), mints a single-booking virtual card
from sirven's own Issuing balance capped at the quoted amount plus the tip ceiling and limited
to ride services, and writes a charge record that pairs every amount with the agent's reason.
when the ride completes, sirven captures from the user exactly what the card spent and closes
the card. sirven never holds a balance for a user.

modules

  stripe_api      the HTTP client. refuses any key that is not a test mode key.
  webhook         Stripe-Signature signing and verification.
  records         the charge-with-rationale record and its file store.
  contract        reads the money fields out of ride connector quote and book results.
  booking_cards   the flow: reserve and mint, authorize, reconcile, settle, cancel.
  fake_stripe     an in-memory stand-in for the slice of the Stripe API used here.
  demo            runs the whole flow, against the stand-in or against Stripe test mode.
"""
