# the ride connector, for agents

The ride connector is a model context protocol server your personal agent calls to get a ride: ask for options, book one, cancel it. It is service-agnostic. Your agent never learns which backend produced a quote; the provider appears only as a value in the options it returns.

This folder is the agent-facing guide. The contract itself (every field, every error code, the versioning policy) lives in `docs/ride-connector-contract.md` and the machine-readable schemas next to it. This guide teaches the contract by example and never redefines it. When the two disagree, the contract wins, and the disagreement is a bug in this guide.

## contract status

| section | status |
| --- | --- |
| the three calls | waiting on the published contract |
| authentication | waiting on the published contract |
| errors | waiting on the published contract |
| idempotency | waiting on the published contract |
| cancellation | waiting on the published contract |
| budget ceilings | waiting on the published contract |
| presenting options to a person | written: [presenting-options.md](presenting-options.md) |

A section marked "waiting" or "moving" is tracked against the contract thread and updated when the contract changes. Do not build against anything this guide says in a section that is not marked stable.
