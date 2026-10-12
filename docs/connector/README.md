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
- [examples/harness.py](examples/harness.py): the client harness, about three hundred lines of standard-library python to read or copy.

## contract status

Documented against contract version `1.0.0`, as of the contract thread's first commit (`4424c92`, October 11, 2026). The contract thread is still active: the contract document `docs/ride-connector-contract.md` and its test suite are not written yet, so every row below can still change.

| section | status |
| --- | --- |
| connecting, and the four calls | matches commit `4424c92`; contract still in progress |
| budget ceilings and constraint flags | matches commit `4424c92`; contract still in progress |
| errors | matches commit `4424c92`; contract still in progress |
| idempotency | matches commit `4424c92`; contract still in progress |
| cancellation | matches commit `4424c92`; contract still in progress |
| the concierge disclosure | matches commit `4424c92`; the sentence comes from the connector itself |
| a replayed booking after its quote expired | **moving**: observed server behavior, not yet in the contract document |
| authentication | **moving**: the contract does not define it yet |
| obtaining a `payment_reference` from the money layer | **moving**: the money layer's interface is not published yet |
| versioning policy | **moving**: waits on `docs/ride-connector-contract.md` |

A section marked moving is tracked against the contract and updated when it changes. Do not build against anything this guide says in a moving section.
