# Per-booking virtual cards through Stripe Issuing

Status, October 11, 2026: built and tested against Stripe test mode behavior, test mode only. Nothing here can reach live mode (see "The test mode lock"). Live mode, real cards, and any real money movement wait for Jose's explicit approval.

Code: [lib/issuing](../lib/issuing). Tests: [tests/issuing/test_issuing.py](../tests/issuing/test_issuing.py), run by `make test`. Demo run: [docs/stripe-issuing-demo-run.txt](stripe-issuing-demo-run.txt).

## Gaps for Jose: what Stripe needs before live mode

These are the approvals and facts only Jose can supply. Each is held, not sent. Sources were read on October 11, 2026.

1. **Apply for Stripe Issuing for agents, "cards for your own business" track.** Stripe's Issuing for agents page lists this product as "Cards for your own business ... Common use cases include buying inventory to resell, covering operational expenses, and making purchases to fulfill a service", with access through "Apply in the Stripe Dashboard". Sirven paying the ride service to fulfill a ride the user bought from sirven is a purchase to fulfill a service. A draft application is in [docs/stripe-issuing-application-draft.md](stripe-issuing-application-draft.md), held for Jose. Source: [docs.stripe.com/issuing/agents](https://docs.stripe.com/issuing/agents). The general Issuing page also says to "Determine your eligibility to use Issuing by contacting Stripe sales": [docs.stripe.com/issuing/how-issuing-works](https://docs.stripe.com/issuing/how-issuing-works).
2. **The consumer-use question is the main approval risk, and Stripe has to answer it.** Stripe's supported use cases page says cards "must always be used for business purposes, and may not be used for personal, family, or household purposes" and "may not be funded partially or entirely by an individual's personal funds". Sirven's design keeps to the letter of this: the cardholder is sirven itself (a company cardholder, never the user), the card is funded from sirven's own Issuing balance, the user never sees or touches the card, and the user's payment is a sale by sirven as merchant of record. But the ride itself is personal travel for the user, and Stripe may read the funding as passing through. The application draft states the model plainly and asks Stripe to confirm it. If Stripe says no, the fallback is the "cards for your platform" track (consumer cards, contact Stripe), which is a different and heavier program. Source: [support.stripe.com/questions/supported-business-use-cases-for-stripe-issuing](https://support.stripe.com/questions/supported-business-use-cases-for-stripe-issuing).
3. **Compliance review of user-facing copy before launch.** Stripe requires marketing and product interfaces for Issuing programs to be submitted for review (about 10 business days), and requires the issuing bank disclosure on materials that market the card program. Sirven does not market a card to users at all (the card is internal plumbing), so the expectation is that the review is light, but Stripe decides that. Charge records and statements must not call the card the user's card. Source: [docs.stripe.com/issuing/commercial-compliance](https://docs.stripe.com/issuing/commercial-compliance).
4. **Business facts only Jose can supply.** Legal entity name, employer identification number, registered business address (the test mode cardholder uses a placeholder San Francisco address), beneficial owners, and the bank account that will top up the Issuing balance. US top-ups pull from that bank account and can take up to 5 business days to land, so the balance has to be pre-funded ahead of ride volume. Source: [docs.stripe.com/issuing/funding/balance](https://docs.stripe.com/issuing/funding/balance.md?push-pull-preference=pull).
5. **A fresh Stripe test mode key.** The Stripe command-line tool on the Mac this was built on is logged in, but its test mode key expired on February 18, 2024, so the demo ran against the in-memory stand-in rather than Stripe's own test mode. Jose runs `stripe login` once, or stores a restricted test key with `bb secret` as `STRIPE_TEST_SECRET_KEY`, and the same demo runs against Stripe test mode with `--stripe-test-mode`. Test mode Issuing may itself need to be switched on in the Dashboard first; that is free.
6. **Real-time authorization endpoint.** Stripe sends `issuing_authorization.request` to an endpoint set in the Issuing settings and waits 2 seconds; with no answer it falls back to the timeout setting. Production needs a public HTTPS endpoint for `serve`, and Jose's choice of timeout fallback (decline is the safe default). Source: [docs.stripe.com/issuing/controls/real-time-authorizations](https://docs.stripe.com/issuing/controls/real-time-authorizations).
7. **Money transmission, confirmed by counsel, not by this thread.** Sirven holds no user balance in version 1: the user's money is a held card payment that sirven captures as a sale, and the ride is paid from sirven's own Issuing balance. Stripe's own disclosure language puts the Issuing balance with "Stripe Payments Company, licensed money transmitter". Whether sirven's merchant-of-record resale needs anything further is a legal question for Jose's counsel.

Costs found: Stripe's Issuing page says Issuing has no setup fees, and the compliance page refers to "Stripe's fee of 0.10 USD" for creating a virtual card. At one card per booking, that is 0.10 USD a ride before any per-transaction pricing. Per-card and per-transaction pricing for this account is not published in the docs read here and should be confirmed in the application conversation. Nothing has been spent.

## The flow

```
booking time   quote (price, tip ceiling, currency) + book (booking identifier)
               -> hold the cap on the user's card        payment intent, capture_method=manual
               -> mint a booking card                    virtual, ride services only, capped
               -> open the charge record                 amounts next to the agent's reason
during ride    the ride service charges the card
               -> spending controls (Stripe side)        category and amount limits
               -> real-time decision (sirven side)       open booking, right currency, under the cap
               -> events update the record               authorizations, captures, reversals, refunds
completion     -> pull the card's full history from Stripe
               -> capture from the user exactly what the card spent (never more than the cap)
               -> or release the hold if nothing was spent
               -> cancel the card
```

The cap is `price + tip_ceiling` from the quote. It is enforced three times: the card's `per_authorization` and `all_time` spending limits, sirven's real-time decision (which also counts pending holds and earlier captures), and settlement, which never captures more than the held amount.

Single-use: the card carries `lifecycle_controls.cancel_after.payment_count` of 1, or 2 when a tip ceiling allows a separate tip charge, so Stripe cancels it on its own even if sirven never got to. Source: [docs.stripe.com/issuing/controls/lifecycle-controls](https://docs.stripe.com/issuing/controls/lifecycle-controls).

Merchant category: `taxicabs_limousines` (merchant category code 4121), the code ride services settle under, and the category Stripe's own testing guide uses for a ride service. Source: [docs.stripe.com/issuing/testing](https://docs.stripe.com/issuing/testing.md?testing-method=with-code).

The user's hold lasts 7 days for an online card payment, so settlement must happen within that window. Source: [docs.stripe.com/payments/place-a-hold-on-a-payment-method](https://docs.stripe.com/payments/place-a-hold-on-a-payment-method).

## Edge cases and what happens

| What happens | Result |
| --- | --- |
| The user's card refuses the hold | No card is minted, no record is written, the booking must not go ahead |
| Minting the card fails after the hold | The hold is released at once |
| A charge from a merchant that is not a ride service | Declined by spending controls before sirven is asked |
| One charge over the cap | Declined by spending controls |
| Charges that add up past the cap | Declined by sirven's real-time decision (`over_cap`) |
| A charge after the booking was cancelled | Declined by sirven (`booking_closed`) |
| Partial reversal, then a smaller capture | The user is charged the captured amount |
| An authorization that expires uncaptured | Nothing is charged; the hold is released |
| The ride service captures more than the cap (a late tip, an error) | The user is charged the cap, never more; the record goes to `needs_review` and sirven absorbs the difference until a person looks |
| A refund after settlement | Passed straight back to the user as a refund on their payment |
| A force capture after settlement | Never charged to the user; the record goes to `needs_review` |
| Webhooks lost, duplicated, or out of order | Duplicates count once; a late event never reopens a closed authorization; settlement always pulls the card's history from the API first, so lost events cannot cause a wrong charge |

A known limit: a tip posted as a new charge after settlement is declined, because the card is closed at settlement. The caller decides when to report completion; it should allow for the ride service's tip window first. A tip added by over-capturing the fare is still caught before settlement.

## The charge-with-rationale record

One JSON file per booking. The user-facing statement renders it like this:

```
booking booking-demo-1 (settled)
  why: cheapest option arriving before the 3pm appointment; under the $25 budget even with the full tip allowance
  you asked: book me a ride to the barber after my 2pm meeting, under $25
  quote quote-demo-1 from a ride service: $18.40, tip allowed up to $5.00
  held on your card at booking: $23.40
  paid to the ride service: $21.40
  charged to you: $21.40
```

Fields: `booking_id`, `quote_id`, `user` (an opaque reference), `state` (`reserved`, `settled`, `cancelled`, `needs_review`), `amounts` (all in minor units: `quoted`, `tip_ceiling`, `cap`, `reserved_on_user_card`, `captured_by_card`, `refunded_to_card`, `charged_to_user`, `refunded_to_user`), `rationale` (the quote, the booking, `reasoning_summary`, `user_request`), `stripe` (object references and the card's last four digits only), `authorizations`, `transactions`, `review_reasons`, and a `timeline` where every entry has a time, a kind, a sentence, and an amount where money moved. Card numbers, security codes, and expiry dates are never written; a test checks it.

## Dependency on the connector contract

The quote and book fields are read in one place, [lib/issuing/contract.py](../lib/issuing/contract.py): `quote_id`, `price.amount_minor`, `price.currency`, `tip_ceiling.amount_minor`, `tip_ceiling.currency`, `provider`, `estimated_arrival`, `estimated_trip_time` on a quote option; `booking_id`, `quote_id`, `cancellation_window` on a book result. The connector contract (docs/ride-connector-contract.md, thread 08) was not published when this was built, so these names follow its brief. If the published names differ, only that file changes. The card never travels back through the contract: the agent sees the booking and the charge record, never card details.

## Running it

```
cd lib && python3 -m issuing.demo                     # in-memory stand-in, no key, no network
cd lib && STRIPE_TEST_SECRET_KEY=... python3 -m issuing.demo --stripe-test-mode
cd lib && python3 -m issuing.demo serve --port 4242 --cardholder ich_...
stripe listen --forward-to localhost:4242/stripe/webhook
```

In test mode the demo needs no webhooks: after each step it reconciles from the API. The key is read from the environment and never printed.

## The test mode lock

`StripeClient` refuses any key that does not start with `sk_test_` or `rk_test_` before it builds a request, and treats any response or event that says `livemode: true` as an error. Turning on live mode is a code change plus Jose's approval, never a configuration slip.

## The in-memory stand-in

[lib/issuing/fake_stripe.py](../lib/issuing/fake_stripe.py) implements the slice of the Stripe API the flow uses, following the documented test mode behavior: spending controls run before the real-time request, the request is signed and must be answered with a `Stripe-Version` header, lifecycle controls cancel the card, captures post negative Issuing transactions and refunds positive ones. It is a stand-in, not Stripe; the `--stripe-test-mode` run is the check on it, and it is waiting on gap 5.
