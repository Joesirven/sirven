# Stripe Issuing for agents: application draft (held for Jose)

Status: draft, not submitted. Nothing here has been sent to Stripe. Jose reviews, fills the bracketed fields, and submits through the Stripe Dashboard (Issuing overview, "Apply") himself, or sends it to Stripe's embedded finance contact form if the Dashboard routes him there.

Where to submit: [dashboard.stripe.com/issuing/overview](https://dashboard.stripe.com/issuing/overview), the path Stripe lists for "Cards for your own business" on [docs.stripe.com/issuing/agents](https://docs.stripe.com/issuing/agents) (read October 11, 2026). Applying is free; it commits to nothing paid.

## Only Jose can supply

- [ ] Legal entity name and type
- [ ] Employer identification number
- [ ] Registered business address
- [ ] Beneficial owners and a control person, with their identity details
- [ ] The bank account that funds the Issuing balance
- [ ] Expected monthly volume he is comfortable stating (a starting estimate is below)
- [ ] The website URL Stripe will review
- [ ] Decision: whether to ask about the consumer-cards track at the same time, as a fallback (see question 1 below)

## Draft answers

**What does your business do?**
Sirven gives an individual a personal agent that acts for them online, plus the network access and tools it needs. One of the first things the agent does is book rides: the user asks for a ride, the agent compares quotes from ride services, and books the one that fits the user's request and budget.

**How will you use Issuing?**
Sirven is the merchant of record for each ride booking. The user pays sirven; sirven pays the ride service. For each booking, sirven creates one virtual card from its own Issuing balance, held by sirven as a company cardholder, and uses it to pay the ride service for that one ride. The card is limited to the ride services merchant category (4121, `taxicabs_limousines`), capped at the quoted fare plus a tip ceiling the user agreed to, set to cancel itself after one or two payments, and cancelled by sirven as soon as the ride is settled. Every authorization also passes through our real-time authorization endpoint, which checks the booking is still open and the running total is under the cap.

This is the "making purchases to fulfill a service" use case on your Issuing for agents page: the cards pay for the service sirven sold.

**Who are the cardholders?**
Sirven only, as a company cardholder. End users are never cardholders, never receive card details, and never interact with the cards.

**How are cards funded?**
From sirven's Issuing balance, topped up from sirven's business bank account. Separately, sirven takes payment from the user for the ride as an ordinary card sale: a manual-capture payment intent holds the quoted fare plus tip ceiling at booking and sirven captures what the ride actually cost when it completes. Sirven holds no balance for users.

**Expected volume (early estimate, for Jose to adjust).**
Launch in San Francisco. [Number] rides a month in the first quarter, average fare around 20 dollars, so roughly [number times 20] dollars a month of card spend, one virtual card per ride.

**Merchant categories.**
`taxicabs_limousines` only, at launch.

**Countries.**
United States only. The cardholder (sirven) and the merchants are all in the United States.

## Questions to put to Stripe in the application

1. Please confirm this model fits commercial Issuing. Your use case guidance says cards "may not be used for personal, family, or household purposes" and "may not be funded partially or entirely by an individual's personal funds". Here the cardholder and funder is sirven, and the purchase fulfills a service sirven sold, but the ride is for an individual's own travel. If you see it as consumer use, which program would you recommend? ([source](https://support.stripe.com/questions/supported-business-use-cases-for-stripe-issuing))
2. Pricing for virtual cards and authorizations at this volume, and whether the 10 cent virtual card fee applies per card.
3. Whether any user-facing material needs compliance review given that users never see or hold a card.
4. Whether ride services' tip and fare adjustment patterns (over-capture after the trip) need any program setting beyond spending controls.
