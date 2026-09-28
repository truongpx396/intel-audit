# Design decisions

Each entry states the decision, the alternative, and **what goes wrong without it**. A decision with
no failure mode attached is a preference, and preferences do not belong in a specification.

Decisions marked **inherited-gap** resolve something the originating design left open, contradictory,
or unimplementable. Two of them — **D3** and **D15** — are the reason this repository is worth
reading even if you never adopt the code.

---

## D1 — `Realm` is the outermost isolation axis · *inherited-gap*

**Decision.** Every key and row carries a `Realm`, outside the tenant. The idempotency guard is
`(realm, tenant_kind, tenant_id, idem_key)`.

**Alternative.** Tenant as the outermost axis, as inherited.

**What goes wrong without it.** Two products sharing one audit deployment share an idempotency key
space. Product A records `invite:42:accepted`; product B's unrelated invite 42 is **silently
swallowed as a replay** and never enters the trail. A missing audit entry is worse than a missing
notification: the trail's whole value is that absence means the thing did not happen.

Verified: `verify-schema.sql` TEST 1.

## D2 — The idempotency guard is its own non-partitioned table · *inherited-gap*

**Decision.** `audit_idem (realm, tenant_kind, tenant_id, idem_key)` is a separate, non-partitioned
table written in the same transaction as the entry.

**Alternative.** The inherited design: a durable `UNIQUE (tenant, idem_key)` (invariant 4) on a table
`PARTITION BY RANGE (created_at)` (invariant 9).

**What goes wrong without it.** The table does not exist. PostgreSQL requires every unique constraint
on a partitioned table to include all partition-key columns:

```
ERROR:  unique constraint on partitioned table must include all partitioning columns
DETAIL:  UNIQUE constraint on table "audit_log_inherited" lacks column "created_at"
         which is part of the partition key.
```

Adding `created_at` to the constraint satisfies Postgres and destroys the guarantee, because the same
`idem_key` at a different timestamp becomes a different key.

This is the **third** subsystem of the originating design to inherit this exact pattern, after
[intel-payment's `credit_ledger`](https://github.com/truongpx396/intel-payment) and
[intel-notification's `notifications`](https://github.com/truongpx396/intel-notification). One
unconstructible shape was copied across three specifications and applied in none of them. That is a
process finding, not three coincidences: a schema nobody runs is prose.

Verified: `make verify-schema` reproduces the failure and asserts its exact reason before applying
the fix.

## D3 — Retirement writes a chain anchor · *inherited-gap*

**This is the most important decision in the repository.**

**Decision.** Retiring an aged partition first records an immutable `audit_chain_anchor` row holding
`(first_seq, last_seq, last_hash, entry_count, range_start, range_end, retired_at, retired_by)`.
`Verify` consults anchors, so a retired range resolves as **provably retired** and the surviving
chain still links back through the anchor's `last_hash`.

**Alternative.** The inherited design: retention retires partitions (invariant 9), and a `Seq` gap is
evidence of tampering (invariant 6). Both, with nothing reconciling them.

**What goes wrong without it.** The two invariants are in **direct contradiction**, and the result is
worse than either failing alone. After one retention run the chain begins at seq N with nothing
before it — which is exactly what deleting rows looks like. So `Verify` reports tampering on a
perfectly healthy log, on every tenant, forever, starting the first time retention runs.

Demonstrated:

```
before retention  seq: 1,2,3,4
after  retention  seq: 3,4
=> Verify() sees the chain starting at seq 3 with no seq 1..2 --
   indistinguishable from deletion, i.e. it reports TAMPERING on a healthy log
```

The failure mode is not a false alarm you learn to ignore — it is worse than that. A system that
cries tampering every month trains its operators to dismiss the alarm, so the one real tampering
event is dismissed too. A tamper-evidence mechanism that cannot distinguish its own housekeeping from
an attack has negative value.

Anchors are themselves append-only (D15): an anchor that could be rewritten would let a retired range
be re-described, which is the same forgery one layer up.

Verified: `verify-schema.sql` TEST 5.

## D4 — The chain head is durable; Redis may cache it, never own it · *inherited-gap*

**Decision.** `audit_chain_head` is a Postgres table, advanced under a row lock in the same
transaction as the append. Redis may cache the head for speed and is treated as advisory.

**Alternative.** The inherited design, which names `audit:head:{kind}:{tenant}` in Redis as
**"authoritative Redis state"**.

**What goes wrong without it.** Redis is not durable. A flush, an eviction, a failover or a cold start
loses the head, and the next append starts `Seq` again from 0. Two outcomes, both bad: the new entry
collides with an existing `Seq` for that tenant, or the chain acquires a permanent break at the
restart point that `Verify` reports as tampering forever. Neither is recoverable by replaying,
because the hashes of everything after the restart were computed from the wrong predecessor.

It is also a direct contradiction of the originating project's own stated principle — its notification
and billing designs both insist Redis is a fast path and never the source of truth. Audit was the one
place that rule was dropped, and it is the place where it matters most.

Verified: `verify-schema.sql` TEST 6.

## D5 — Sealing happens at durable-append time · *inherited-gap*

**Decision.** `Seq` is assigned and the hash computed inside the transaction that durably appends.
The `buffered` durability mode buffers **unsealed** entries.

**Alternative.** Seal, then buffer, then append.

**What goes wrong without it.** A sealed-then-lost entry consumes a `Seq` that never reaches the
store, leaving a permanent gap indistinguishable from deletion — the D3 failure, arriving through the
performance knob instead of through retention. The buffering mode exists to trade durability for
throughput on low-stakes entries; it must not be able to corrupt the integrity of the chain those
entries share with security events.

## D6 — Multi-sink fan-out goes through an outbox · *inherited-gap*

**Decision.** The primary sink's append and one `audit_sink_outbox` row per additional sink are
written in one transaction; a drainer delivers to the rest at least once.

**Alternative.** Invariant 8's "fan-out to multiple sinks is all-or-nothing per entry".

**What goes wrong without it.** It cannot be implemented as stated. Postgres and a SIEM cannot share a
transaction, so "all-or-nothing" across them is a two-phase commit nobody is going to build. Without
an outbox the honest behaviour is best-effort: the entry lands in Postgres, the SIEM forward fails,
and the compliance backhaul silently has a hole precisely during the incident that caused the load.
This is the same two-store problem metering and notifications both solved the same way.

## D7 — Retention is per severity, and a legal hold suspends it

**Decision.** `audit_retention_policy` is keyed by `(realm, tenant, severity)` with its own window,
plus a nullable `hold_until` that suspends retirement.

**Alternative.** One global retention window.

**What goes wrong without it.** Per-tool-call `info` telemetry and a `security` access-control
decision have retention requirements that differ by years. A single window forces one of two bad
choices: keep the noise as long as the evidence and pay for it, or discard the evidence as early as
the noise and fail an audit. And without a hold, routine retention retires records for a tenant under
active investigation — a legal problem created by a cron job.

Verified: `verify-schema.sql` TEST 7.

## D8 — The no-body rule is enforced sink-side as well

**Decision.** Redaction runs in the recorder *and* the sink re-checks before appending.

**Alternative.** Redact once in the recorder, as inherited.

**What goes wrong without it.** The recorder is a library the host compiles in. A producer that
constructs `Attributes` with a prompt, a response body or a secret gets it durably written, and the
whole point of invariant 5 is that the trail is safe to retain for years and ship to a SIEM. A single
careless producer turns the compliance artifact into the largest secret leak in the system. Defence
in depth matters here specifically because the trail outlives the code that wrote it.

## D9 — `Verify` reports the window it actually verified

**Decision.** `VerifyReport` carries the `(from_seq, to_seq)` range covered and the anchors it
traversed, not just `Intact bool`.

**Alternative.** The inherited `VerifyReport{Checked, Intact, BreakSeq, Detail}`.

**What goes wrong without it.** "Intact" without a range is unfalsifiable. A verifier that checked
three entries and one that checked three million both report `Intact: true`, and after D3's anchors
exist, a caller cannot tell whether a clean result covered the disputed period or stopped at an
anchor boundary before it. In a dispute that distinction is the entire question.

## D10 — `Seq` is assigned under a database lock, not a cache increment

**Decision.** The next `Seq` comes from `SELECT ... FOR UPDATE` on the tenant's `audit_chain_head`
row inside the append transaction.

**Alternative.** A Redis `INCR` on the head key.

**What goes wrong without it.** `INCR` is atomic but not transactional with the Postgres append. A
crash between the increment and the insert burns a `Seq` — a permanent gap, the D3 failure again. And
a retry after the crash takes a *new* `Seq`, so the entry that eventually lands is not the one the
first attempt sealed. Taking the number inside the transaction that persists the row makes the two
succeed or fail together.

## D11 — `RecordBatch` assigns contiguous sequences in one transaction

**Decision.** A batch takes `N` sequences atomically and appends all entries or none.

**Alternative.** Loop `Record` per entry.

**What goes wrong without it.** An agent step that calls six tools becomes six independent
transactions. A crash midway leaves a partially recorded step — three tool calls in the trail and
three that happened but are not recorded, with no marker distinguishing that from a step that only
made three calls. For an AI audit trail, "what did the agent actually do" is the question being
asked, and a partial answer is a wrong answer.

## D12 — Hash canonicalization is specified, not implied

**Decision.** `canonical(entry)` is defined explicitly: UTF-8 JSON, keys sorted lexicographically, no
insignificant whitespace, timestamps as RFC 3339 in UTC with millisecond precision, absent optional
fields omitted rather than null.

**Alternative.** "H(PrevHash || canonical(Entry) || Seq)" with `canonical` undefined, as inherited.

**What goes wrong without it.** `Verify` is only meaningful if the verifier recomputes the same bytes
the sealer hashed. Undefined canonicalization means a Go map iteration order, a JSON library upgrade,
or a re-implementation in another language produces different bytes for the same entry — so the chain
fails to verify with no tampering involved. Worse, it fails *later*, during the dispute the mechanism
exists for, when the original binary may be long gone.

## D13 — `Actor.Role` is descriptive and never an authorization input

**Decision.** `Role` is recorded as it was at the time and is documented as non-authoritative. Nothing
reads it to make a decision.

**Alternative.** Leave it ambiguous, as inherited ("descriptive, never a routing input" is stated for
`Attributes` but not for `Role`).

**What goes wrong without it.** A field that looks like a role invites a permission check against it.
The trail records history; roles change. Authorizing against the role stored on a two-year-old entry
either grants access that was revoked or denies access that was granted, and it makes the audit log —
a write-mostly, retained, SIEM-exported artifact — part of the live authorization path.

## D14 — One table, `actor_kind` as the discriminator

**Decision.** A member action, an AI tool call and a sandbox run are one `audit_entry` row
distinguished by `actor_kind`.

**Alternative.** The inherited `audit_log` + `agent_audit_log` + `sandbox_run` split.

**What goes wrong without it.** "What happened to resource X" becomes a three-way `UNION` over
divergent column sets, and every new audited surface adds a fourth. The query that matters most
during an incident is the one the schema makes hardest, and each new table silently degrades it.

## D15 — Append-only is enforced by the database · *inherited-gap*

**Decision.** A trigger rejects `UPDATE` and `DELETE` on `audit_entry` and `audit_chain_anchor`, and
the application role is granted only `SELECT, INSERT`.

**Alternative.** The inherited invariant 1: "the audit surface exposes no update or delete method",
with a contract test whose body is a comment saying a reviewer should check the interface never grows
one.

**What goes wrong without it.** The absence of a method in a Go interface constrains the application
and nothing else. It does not constrain a `psql` session, an ORM, a migration script, a backup
restore, a support engineer, or an attacker who has reached the database — and *that last one is the
adversary the audit trail exists to catch*. A tamper-evidence scheme whose immutability rests on
nobody calling the wrong function protects against accidents while leaving the threat model's actual
attacker untouched.

The trigger makes tampering require dropping the trigger, which is itself a privileged DDL action a
competent deployment logs elsewhere. That is the difference between evidence and an honour system.

Verified: `verify-schema.sql` TEST 4.

---

## Open decisions

None blocking Phase 1. The largest honest limitation is deferred deliberately:

| Question | Why it waits | Where |
|---|---|---|
| How is the trail protected from **the operator**? | Phase 1 is tamper-evident against anyone without database *and* deployment access. An operator who can drop a trigger can also recompute the whole chain. Closing that needs external anchoring, which is a different trust model, not a bigger hash | [Phase 2](../002-anchoring-legal-hold/) |
| What does a **legal hold** do to a chain mid-retention? | The `hold_until` column exists; the interaction between a hold, an anchor and a partially retired range needs the anchoring model settled first | [Phase 2](../002-anchoring-legal-hold/) |
