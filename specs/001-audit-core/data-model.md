# Data model

The authoritative schema is [`migrations/`](../../migrations/), verified against PostgreSQL 16 by
`make verify-schema`. This document explains the shapes and the rules the DDL cannot express.

## Identity: three opaque axes

```
realm      "my-product"                    ← WHICH PRODUCT. Outermost; isolates the key space.
  tenant   {kind:"workspace", id:"w1"}     ← the host's isolation boundary
    actor  {kind:"agent", id:"u1", role:…} ← WHO acted; role is descriptive only
```

The engine never parses any of them. A human action, an AI tool call, a service job and a sandbox run
differ only by `actor_kind` — that is what keeps "what happened to resource X" a single query
([D14](design-decisions.md#d14)).

## Tables

### `audit_entry` — the trail

One immutable row per audited event. Partitioned by range on `created_at` so retention retires whole
ranges. The primary key carries `created_at` because Postgres requires it — which is precisely why
the idempotency guard lives elsewhere ([D2](design-decisions.md#d2)).

Three indexes serve the three real queries: the chain walk (`seq` order), the console list (newest
first), and `BySubject` — the cross-cutting "what happened to X" that the inherited two-table split
made a `UNION`.

RLS is `ENABLE`d **and** `FORCE`d. Forcing matters: without it the table owner bypasses its own
policy, and the owner is the role the application connects as.

`attributes` holds audit detail — trace id, token cost, old→new value. **Never** a payload. The
no-body rule is enforced when recording and re-checked when appending
([D8](design-decisions.md#d8)).

### `audit_idem` — the exactly-once guard

`(realm, tenant_kind, tenant_id, idem_key)` as primary key, non-partitioned, written in the same
transaction as the entry. Separate because the obvious design cannot be created on a partitioned
table; see [D2](design-decisions.md#d2) for the error and why adding the partition key would silently
destroy the guarantee.

### `audit_chain_head` — the durable sequence head

One row per `(realm, tenant)`, advanced under `SELECT … FOR UPDATE` inside the append transaction.

This is a **table, not a cache key**. The originating design named Redis as "authoritative" for it,
which cannot hold: losing Redis restarts `seq`, producing either a collision or a permanent false
break that no replay can repair ([D4](design-decisions.md#d4), [D10](design-decisions.md#d10)).

### `audit_chain_anchor` — what makes retention compatible with verification

The table this engine exists for. Retiring a range records `(first_seq, last_seq, last_hash,
entry_count, range_start, range_end, retired_at, retired_by)` **before** the range goes away.

Without it, retention and tamper-evidence contradict each other: a retired range leaves the chain
starting at seq N with nothing before it, which is what deletion looks like, so verification reports
tampering on a healthy log after every retention run ([D3](design-decisions.md#d3)).

Anchors are append-only too — a rewritable anchor would let a retired range be re-described, which is
the same forgery one level up.

### `audit_retention_policy` — per-severity windows and legal hold

Keyed by `(realm, tenant, severity)`. `info` telemetry and `security` evidence differ in required
retention by years; one global window forces keeping the noise as long as the evidence or discarding
the evidence as early as the noise.

`hold_until` suspends retirement for a tenant under investigation — retiring records during a dispute
is a legal problem created by a cron job ([D7](design-decisions.md#d7)).

### `audit_sink_outbox` — durable fan-out

One row per additional sink, committed with the entry. Postgres and a SIEM cannot share a transaction,
so "all-or-nothing fan-out" is only real through an outbox ([D6](design-decisions.md#d6)).

## Redis (optional)

| Key | Role | If lost |
|---|---|---|
| `audit:head:{realm}:{tag}` | advisory cache of the chain head | a read falls through to Postgres; **nothing breaks** |

That is the whole Redis surface, and it is optional. Compare the originating design, where this key
was the authoritative head.

## Invariants the DDL cannot express

1. The entry, its `audit_idem` row, the head advance and any outbox rows are written in one
   transaction, or none are.
2. Sealing happens inside that transaction — never before buffering ([D5](design-decisions.md#d5)).
3. An anchor is written **before** its range is retired, never after.
4. `canonical(entry)` is the form specified in the contract; changing it is a breaking change to
   verification ([D12](design-decisions.md#d12)).
5. `actor_role` is never read for an authorization decision ([D13](design-decisions.md#d13)).
6. `security` and `critical` entries are durable before the producing action is acknowledged.

These are asserted by the contract tests, because a schema cannot hold them.
