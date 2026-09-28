# Specification: Audit core

**Status**: normative, implementation not started.
**Contracts**: [contracts/](contracts/) · **Data model**: [data-model.md](data-model.md) ·
**Decisions**: [design-decisions.md](design-decisions.md) · **Build order**: [tasks.md](tasks.md)

Requirements carry `AR-0NN` ids and success criteria `AS-0NN`. The mapping from the originating
project's `FR-023`/`FR-024` is in [PROVENANCE.md](../../PROVENANCE.md).

## Problem

A system needs to answer, months later and to someone who does not trust it: *who did this, to what,
when, and how do I know the record was not edited?* Four things make that hard, and each is easy to
get subtly wrong:

1. **Immutability that is real.** "We never update this table" is a habit, not a guarantee.
2. **Tamper-evidence that survives housekeeping.** A hash chain and a retention policy will fight
   each other unless someone reconciles them explicitly.
3. **One shape for every actor.** Humans, agents, services and sandboxes must be queryable together.
4. **Evidence that is safe to keep.** A record retained for years and shipped to a SIEM must never
   contain payloads or secrets.

## Requirements

### Recording

- **AR-001**: The system MUST record every audited event as one immutable, append-only entry carrying
  its realm, tenant, actor, action, subject, severity, timestamps and an idempotency key.
- **AR-002**: A member action, an automated agent action, a service job and an isolated execution
  MUST be the same record shape, distinguished by an opaque actor kind. Adding an audited surface
  MUST NOT require a schema change.
- **AR-003**: Recording MUST be idempotent on `(realm, tenant, idem_key)`. A replay MUST produce no
  second entry, MUST consume no sequence number, and MUST report itself as a replay.
- **AR-004**: A batch MUST be recorded atomically with contiguous sequence numbers, so a multi-step
  action cannot be partially recorded.
- **AR-005**: Entries classified `security` or `critical` MUST be durable before the producing action
  is acknowledged, regardless of any buffering configuration.

### Integrity

- **AR-006**: Each entry MUST carry a monotonic per-`(realm, tenant)` sequence and link the previous
  entry by hash.
- **AR-007**: The sequence head MUST be durable and advanced within the same transaction that
  persists the entry. A cache MAY hold it; a cache MUST NOT own it.
- **AR-008**: Sealing MUST be deterministic over a **specified** canonical form, so an independent
  implementation can recompute and verify it.
- **AR-009**: Verification MUST report the range it covered, not merely a boolean.
- **AR-010**: The system MUST reject `UPDATE` and `DELETE` on audit entries **at the storage layer**,
  not only by omitting them from an interface.

### Retention

- **AR-011**: Retention MUST retire whole time ranges rather than removing individual entries.
- **AR-012**: Retiring a range MUST first record an immutable anchor covering it, so that a verifier
  can distinguish a retired range from deleted entries. Retention MUST NOT cause verification to
  report tampering.
- **AR-013**: Retention windows MUST be configurable per severity, and a legal hold MUST suspend
  retirement for a tenant.

### Isolation and safety

- **AR-014**: Every read MUST be scoped to its realm and tenant at the data layer. A trail MUST NEVER
  be readable across tenants or realms, regardless of role.
- **AR-015**: The realm MUST participate in the idempotency key space.
- **AR-016**: Entries MUST NOT contain bodies — no payloads, prompts, responses, file contents or
  secrets. Only references and hashes. This MUST be enforced both when recording and when appending.
- **AR-017**: Actor role MUST be recorded as descriptive history and MUST NOT be consulted for any
  authorization decision.

### Extensibility and deployment

- **AR-018**: Adding a durable target MUST be implementing one interface and registering it, with no
  change to sealing, redaction, idempotency or retention.
- **AR-019**: Fan-out to additional targets MUST be durable: the primary append and the intent to
  deliver elsewhere MUST commit together.
- **AR-020**: The engine MUST be adoptable as an in-process library and as a standalone service with
  identical semantics, and MUST NOT import host code.

## Success criteria

- **AS-001**: **100% tenant-scoping correctness.** No entry is ever readable outside its realm and
  tenant. Any violation is a release blocker.
- **AS-002**: **Exactly-once.** A replayed event yields one entry and one sequence number, in 100% of
  duplicate cases.
- **AS-003**: **Immutability holds against a database session**, not merely against the application.
  Demonstrated by attempting both mutations directly and having the storage layer reject them.
- **AS-004**: **Verification is stable across retention.** A log that has undergone any number of
  retention runs still verifies intact, with retired ranges resolved through anchors.
- **AS-005**: **The chain survives cache loss.** Flushing the cache and recording again produces no
  gap, no collision and no verification failure.
- **AS-006**: Verification of a tampered entry identifies the first offending sequence number.
- **AS-007**: No entry ever contains a body, asserted by a redaction test over adversarial input.
- **AS-008**: Adding a sink touches only new files plus one registration line.
- **AS-009**: The module builds and tests green with no host present.

## Edge cases

| Case | Required behaviour |
|---|---|
| Producer retries after a timeout | Second call reports a replay; no second entry, no consumed sequence (AR-003) |
| Crash between sealing and appending | No sequence is consumed; the retry seals afresh (AR-007, AR-003) |
| Cache flushed, service restarted | Sequence continues from the durable head (AR-007, AS-005) |
| Retention runs, then an auditor verifies across the boundary | Verification resolves the retired range through its anchor and reports intact (AR-012, AS-004) |
| Someone edits a row directly in the database | Rejected by the storage layer; if forced by removing the guard, verification detects it (AR-010, AS-006) |
| An anchor is rewritten to re-describe a retired range | Rejected — anchors are append-only too (AR-010) |
| A producer puts a prompt body in attributes | Stripped when recording and rejected when appending (AR-016) |
| Two products share a deployment and reuse an idempotency key | Both record; the realm separates them (AR-015) |
| A tenant is under investigation when retention runs | Legal hold suspends retirement for that tenant (AR-013) |
| An agent step calls six tools and crashes after three | Either all six or none are recorded (AR-004) |
