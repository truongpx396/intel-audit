# Specification: External anchoring & legal hold (Phase 2)

**Status: designed, not started. Depends on [Phase 1](../001-audit-core/).**

Phase 1 makes the trail tamper-evident against anyone without simultaneous database and deployment
access. This phase addresses the party it does **not** defend against: whoever runs the system.

## Why this is a separate phase

Phase 1's integrity rests on a hash chain stored in the same database it protects. An operator who
can drop a trigger can also recompute every hash from the first entry forward and produce a
internally consistent forged history. Nothing inside the system can detect that, because the system
holds every input to the check.

The only fix is to publish something an operator cannot retract, to somewhere they do not control.
That is a change in **trust model**, not a stronger hash — which is why it is a separate phase rather
than a hardening pass, and why Phase 1's documentation says "tamper-evident" everywhere and never
"tamper-proof".

## Requirements

### Anchoring

- **AR-101**: The system MUST periodically publish a signed chain head — `(realm, tenant, seq, hash,
  timestamp)` — to one or more external anchors it does not control.
- **AR-102**: At least one anchor implementation MUST require no counterparty relationship (an RFC
  3161 timestamp authority, or a public transparency log).
- **AR-103**: An anchor publication MUST itself be recorded as an audit entry, so the anchoring
  history is part of the trail.
- **AR-104**: Verification MUST be able to prove that a given entry existed **before** a given anchor
  time, using only the entry, the chain and the external anchor.
- **AR-105**: A failed anchor publication MUST alarm and MUST NOT silently degrade. An engine that
  stops anchoring without telling anyone is worse than one that never anchored, because the gap is
  invisible in exactly the period under dispute.
- **AR-106**: Anchoring MUST be resumable after an outage without leaving an unanchored range
  unrecorded.

### Independent verification

- **AR-107**: The system MUST export a verification bundle — entries, chain metadata, anchors and
  their external proofs — that a third party can check **without access to the system**.
- **AR-108**: The verification tool MUST be runnable standalone and MUST NOT depend on the engine's
  database.
- **AR-109**: A bundle MUST state precisely what it proves and what it does not, including the
  unanchored tail.

### Legal hold against anchored ranges

- **AR-110**: A legal hold MUST suspend retirement for a tenant, including ranges already scheduled.
- **AR-111**: Placing and lifting a hold MUST be audited entries, and a lift MUST record who
  authorized it.
- **AR-112**: A hold placed **after** a range was retired MUST surface the anchor for that range, so
  the response to a discovery request is "retired on date D under policy P, anchored as A" rather
  than silence.

## Success criteria

- **AS-101**: A forged history is detectable by a third party holding only a bundle and the public
  anchor — including when the forger controlled the database throughout.
- **AS-102**: Every entry is anchored within one anchoring interval, and the unanchored tail is
  always explicitly reported.
- **AS-103**: The standalone verifier reproduces the engine's verdict on both an intact and a tampered
  bundle, with no access to the engine.
- **AS-104**: A legal hold prevents retirement in 100% of cases, including a hold placed while
  retention is mid-run.

## Open questions

| Question | Options |
|---|---|
| Which anchor is the default? | RFC 3161 needs no counterparty but needs a TSA; a transparency log is public but leaks tenant activity *timing*; a counterparty anchor is private but needs a relationship |
| Per-tenant or per-realm anchoring? | Per tenant is precise and expensive; per realm is cheap but a single anchor covers tenants that may not trust each other |
| Does an anchor leak? | A head hash reveals nothing about content, but publication *cadence* reveals activity volume. Constant-rate anchoring costs more and leaks less |

Genuinely open, and they depend on a deployment's adversary. Recorded rather than guessed.
