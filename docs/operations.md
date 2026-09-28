# Operations

Written for whoever is on call, so each section leads with the symptom.

## The moving parts

| Component | Shape | Notes |
|---|---|---|
| `Recorder` | in-process in producers, or the gRPC service | `security`/`critical` writes are synchronous |
| Retention | scheduled, **single owner** | Writes an anchor, *then* retires |
| Fan-out drainer | queue-group workers | Delivers to secondary sinks from the outbox |
| Verification | on demand | Expensive; not on a request path |
| Anchoring | Phase 2, not built | |

## Alarms worth having

| Alarm | Threshold | Why |
|---|---|---|
| `audit.record.failed` | any, for `security`/`critical` | A failed security write must fail its producing action. If you see these, actions are proceeding unlogged |
| `audit.verify.broken` | any | Either real tampering or a bug in canonicalization. Both are urgent, for different reasons |
| `audit.chain.head_stale` | head age > expected append interval | Recording has stopped for a tenant that should be active — silence in an audit log is not good news |
| `audit.outbox.depth` | rising > 5 min | The compliance backhaul is falling behind |
| `audit.partition.missing` | next month absent | Provisioning lapsed; inserts start failing at month roll |
| `audit.retention.anchor_missing` | any retirement without an anchor | **Stop retention immediately.** This is the one that silently destroys verifiability |

## Playbooks

### Verification reports a break

1. Get the `break_seq` and `detail` from the report. `seq_gap` and `hash_mismatch` mean different
   things.
2. **`seq_gap`** — first check anchors. A gap covered by an anchor is retirement, not tampering, and
   a verifier that did not consult anchors is the bug. If no anchor covers it, entries are missing:
   check whether retention ran without writing one.
3. **`hash_mismatch`** — an entry's content no longer matches its hash. Before declaring an incident,
   confirm the canonical form has not changed underneath you: a library upgrade that reorders JSON
   keys produces exactly this, on every entry after the upgrade. A mismatch on *one* entry with
   intact neighbours is tampering; a mismatch on *everything after a deploy* is canonicalization.
4. Preserve state before investigating. The trail is evidence.

### Retention

Retention **writes an anchor, then retires the range**. Never the reverse: a crash between them must
leave a retirable range rather than an unexplained gap.

Before enabling retention in a new deployment, verify a chain across a retirement boundary in staging.
A deployment running retention without anchors produces a log that reports tampering forever, and the
damage is not undoable — the retired entries are gone, so the gap can never be explained afterwards.

### The chain head looks wrong

The head is a Postgres row, not a cache key. If a Redis cache is configured and disagrees with
Postgres, Postgres wins and the cache entry is discarded — a stale cache can never cause a bad seal,
because sealing reads the durable head inside the append transaction.

If the head row is *missing* for an active tenant, do not recreate it by hand: recompute it from
`max(seq)` for that tenant, and record what you did. A hand-typed head is a forged chain link.

### Partition provisioning

There is deliberately no default partition — a missing one fails inserts loudly rather than silently
filling a catch-all that can never be retired. Provision monthly and alarm on absence.

## Capacity notes

- The chain head serializes appends **per tenant**, not globally. A hot tenant is the contention unit;
  batching amortizes it.
- `BySubject` is index-covered. The query that degrades first is an unfiltered cross-tenant admin
  listing, which is not on any user path and should not be put on one.
- Verification cost is linear in the range. Verify on demand, not on a schedule, unless you have
  budgeted for it.
