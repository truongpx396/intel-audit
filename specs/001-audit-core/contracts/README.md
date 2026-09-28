# Contracts

The normative interfaces. Where a contract and prose elsewhere disagree, the contract wins.

| Contract | What it fixes | Consumers |
|---|---|---|
| [audit-ports.md](./audit-ports.md) | **The core.** Domain types, `Recorder`/`Sink`/`HashChain`/`AuditQuery`, the invariants, the durability knob, contract tests, the module layout | Everything |
| [rest-api.md](./rest-api.md) | The investigator-facing HTTP surface: list, by-subject, verify, anchors, retention policy | Admin console, SIEM export |

There is no separate gRPC file: the producer surface is the same `Recorder` port over the wire, and
splitting it invites the two to drift.

## Reading order

1. **[design-decisions.md](../design-decisions.md)** — unusually, read this *first* here. Two entries
   (D3 and D15) change what the contract means, and the contract was carried from a design that
   predates them.
2. **audit-ports.md** — the domain types and the `Sink`/`Actor`/`Tenant` seams.
3. **[data-model.md](../data-model.md)** — how the invariants land in tables.
4. **[research.md](../research.md)** — the originating research, carried with its history.
5. **rest-api.md** — only when integrating that boundary.

## Stability

| | |
|---|---|
| **Frozen** | The domain types, `Recorder`, `Sink`, the invariants, **and `canonical()`** |
| **Additive** | New sinks, actor kinds, actions, severities, config fields with defaults |
| **Internal** | Adapter implementations, SQL, index layout, the Redis cache |

`canonical()` is frozen for an unusual reason: it is not an implementation detail but part of the
verification contract. Changing it invalidates every hash ever computed, so it is a breaking change to
evidence, not to code ([D12](../design-decisions.md#d12)).
