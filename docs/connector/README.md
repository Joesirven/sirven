# the ride connector, for agents

The ride connector is a model context protocol server your personal agent calls to get a ride: ask for options, book one, follow it, cancel it. It is service-agnostic. Your agent never learns which backend produced an option; the ride service appears only as the value of `provider`.

This folder is the agent-facing guide. The contract itself is the schema at `connectors/ride/schemas/v1/ride-connector.schema.json` together with the contract document `docs/ride-connector-contract.md`. This guide teaches the contract by example and never redefines it. When the two disagree, the contract wins, and the disagreement is a bug in this guide.

## try it in a minute

From a checkout of the sirven repository, with python 3.8 or newer and nothing else installed:

```bash
python3 docs/connector/examples/harness.py
```

The harness starts the connector against fake backends (no network, no money) and talks to it over standard input and output, as an agent would. It runs four scenarios: a booking, a budget-constrained quote, a cancellation, and a blocked ride. Each prints the calls it makes and what the agent would say to the person, checks the results, and the harness exits 1 if any check fails. Run one scenario with `harness.py barber` (or `budget`, `cancel`, `blocked`); add `--json` to see every raw result.

## read next

- [calling-the-connector.md](calling-the-connector.md): connecting, authentication, the four calls, budget ceilings, errors, idempotency, cancellation, the concierge disclosure, versioning.
- [presenting-options.md](presenting-options.md): how to show ranked options to a person, when to ask, and what to say when a ride is blocked.
- [examples.md](examples.md): the four scenarios as conversations, with the requests and results behind them.
- [examples/harness.py](examples/harness.py): the client harness, a little over three hundred lines of standard-library python to read or copy.

## contract status

Documented against contract version `1.0.0`, as published in [docs/ride-connector-contract.md](../ride-connector-contract.md) on October 11, 2026, and checked against the contract thread's commit `c8a15e1`.

| section | status |
| --- | --- |
| connecting, and the four calls | stable: matches the published contract |
| budget ceilings and constraint flags | stable |
| errors | stable |
| idempotency, including a replayed booking after its quote expired | stable |
| cancellation | stable |
| versioning | stable: a summary; the contract document has the full policy |
| the concierge disclosure: where and when to show it | stable |
| the concierge disclosure: its wording | **moving**: placeholder text awaiting Jose's approval; agents pass on whatever the connector returns |
| authentication | **moving**: the contract does not define it yet |
| obtaining a `payment_reference` from the money layer | **moving**: the money layer's interface is not published yet |

A section marked moving is tracked against the contract and updated when it changes. Do not build against anything this guide says in a moving section.
