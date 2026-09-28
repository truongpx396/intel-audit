# Roadmap

Written to be honest about what this is and is not, because an audit trail that overstates its
guarantees is worse than none: it produces confident answers to compliance questions it cannot
actually answer.

## What this is

**An append-only, tamper-evident record of what happened**, for systems where "who did this, to what,
when, and can you prove the record wasn't edited" must have an answer. It is domain-agnostic: a
member action, an AI tool call, a service job and a sandbox execution are one record shape
distinguished by an opaque `actor_kind`.

In scope and designed: one unified entry, per-tenant hash chaining with verification, database-
enforced immutability, exactly-once recording, tenant-scoped reads, per-severity retention that
records anchors so it cannot be mistaken for deletion, pluggable sinks with an outbox for fan-out,
and both deployment shapes (library, or container behind gRPC).

## What this is not

**It is tamper-evident, not tamper-proof.** Phase 1 detects modification by anyone who does not hold
database *and* deployment access simultaneously. It does **not** defend against your own operator: a
sufficiently privileged person can drop the trigger and recompute the entire chain. Closing that gap
requires publishing chain heads somewhere you do not control — [Phase 2](#phase-2--external-anchoring--legal-hold),
designed and not built. Anyone telling you a self-hosted log is tamper-proof without external
anchoring is selling something.

It is also **not** a log aggregator (it records domain events, not application logs), **not** a SIEM
(it feeds one), and **not** an APM or tracing system (it carries a `trace_id` to correlate with one).

**If you do not need provable immutability, you probably want something simpler:**

| Instead | When |
|---|---|
| A plain `events` table | You want history for product features — activity feeds, undo, debugging. Most systems, correctly |
| **OpenTelemetry + your log stack** | You want observability and debugging, not evidence |
| **AWS CloudTrail / GCP Cloud Audit Logs** | You need infrastructure-level audit and live on one cloud |
| **Splunk / Elastic / Datadog** | You need search and alerting across many sources; this feeds them as a sink |
| **AWS QLDB, immudb** | You want a cryptographically verifiable ledger as the database itself |
| **this** | You need a domain audit trail you own, with opaque actors and tenants, immutability the database enforces, and retention that does not break verification |

---

## Phase 1 — Audit core

**Status: designed and normative. Implementation not started.** → [specs/001-audit-core](specs/001-audit-core/)

The unified entry, the durable per-tenant chain, database-enforced append-only, exactly-once
recording, tenant-scoped queries, per-severity retention with anchors and legal hold, the sink
registry with outbox fan-out, and both transports.

**Required infrastructure: PostgreSQL.** Redis is optional and advisory — it may cache the chain
head, never own it. That is a deliberate reduction from the originating design.

## Phase 2 — External anchoring & legal hold

**Status: designed, not started. Depends on Phase 1.** → [specs/002-anchoring-legal-hold](specs/002-anchoring-legal-hold/)

The phase that changes the trust model rather than adding features. Periodically publishes a signed
chain head to somewhere the operator does not control — an RFC 3161 timestamp authority, a
transparency log, or a counterparty — so a rewritten history is detectable *even by the party that
holds the database*. Plus legal hold mechanics against anchored ranges, third-party attestation
export, and verification receipts a counterparty can check independently.

Without this, "the log says so" is only as strong as trust in whoever runs the log. With it, that
becomes a checkable claim.

## Phase 3 — Access transparency & analytics

**Status: not designed.** Listed so its absence is a decision rather than an oversight.

Who *read* the trail (reads are currently unaudited), anomaly detection over actor behaviour,
retention-policy attestation reports, and a query surface for investigators who are not engineers.

---

## Non-goals, permanently

- **Deciding what is worth auditing.** Producers emit entries; this engine does not instrument callers.
- **Storing bodies.** Refs and hashes only. A trail retained for years and exported to a SIEM is the
  worst possible place for prompts, payloads or secrets.
- **Interpreting identity.** What a `Tenant` or `Actor` *means* is the host's; the engine treats both
  as opaque and will not grow a notion of "user".
- **Being the authorization path.** The trail records what a role was; it never decides what a role
  may do.
