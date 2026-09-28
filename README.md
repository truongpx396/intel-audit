# intel-audit

**A reusable, tamper-evident audit trail.** One append-only record for every actor — a person, an AI
agent, a service, a sandbox — with a per-tenant hash chain you can verify, retention that does not
break that chain, and pluggable durable sinks. Adopt it as a Go library or run it as a container.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)

> ## ⚠️ Status: design complete, **implementation not started**
> This repository contains the **specification** — ports, data model, migrations verified against
> PostgreSQL 16, and deployment scaffolding. There is **no Go code yet**, so the snippets below
> describe the intended interface. [ROADMAP.md](ROADMAP.md) says what exists, what is designed and
> what is deliberately absent; [tasks.md](specs/001-audit-core/tasks.md) is the build order.
>
> **Scope, stated honestly:** this records *what happened* so it can be proven later. It is tamper-
> **evident**, not tamper-**proof**: Phase 1 detects modification by anyone without simultaneous
> database and deployment access. Defending against your own operator needs external anchoring, which
> is [Phase 2](specs/002-anchoring-legal-hold/) and not built.

```text
        PRODUCERS (auth · billing · agent · admin · sandbox · approval)
                    │  Record(entry)  ·  RecordBatch(entries)
                    ▼
        ┌── Recorder ──────────────────────────────────────────────┐
        │  redact (no bodies, ever)  →  seal (seq + prev_hash)     │
        │  both inside ONE transaction with the durable append     │
        └──────────────────────────┬───────────────────────────────┘
                                   ▼
        audit_entry (append-only, RLS, partitioned)  +  audit_idem
        audit_chain_head (durable seq)  ·  audit_chain_anchor (retirement proof)
                                   │
                                   ▼  outbox
        additional sinks: kafka · s3-append · splunk · yours
```

---

## Why this exists

Most audit trails are a table with an `INSERT` and good intentions. Four things go wrong, and this
engine is the same machinery with them designed out:

| The usual mistake | What it costs | What this does instead |
|---|---|---|
| A table per audited domain | "What happened to resource X" becomes a `UNION` over divergent shapes, and every new surface adds one | **One `audit_entry`**, `actor_kind` as the discriminator |
| Append-only enforced only by not writing an `UPDATE` | Constrains your code and nothing else — not a `psql` session, and not the attacker the trail exists to catch | A **database trigger** plus `SELECT, INSERT`-only grants |
| A hash chain whose head lives in a cache | Losing the cache restarts `seq`, permanently breaking the chain | The head is **durable**; the cache is advisory |
| Retention that retires partitions under a chain that treats gaps as tampering | Every retention run makes a healthy log **report tampering** | Retirement records an **anchor**, so retired ≠ deleted |

## What it guarantees

| Guarantee | How | Verified |
|---|---|---|
| **A trail is readable only by its tenant** | RLS over `(realm, tenant)`, forced | [TEST 3](scripts/verify-schema.sql) |
| **Exactly-once recording** | `audit_idem (realm, tenant, idem_key)`, same transaction as the entry | [TEST 2](scripts/verify-schema.sql) |
| **Rows cannot be changed or removed** | Trigger rejects `UPDATE`/`DELETE`; role has no privilege for either | [TEST 4](scripts/verify-schema.sql) |
| **Retention does not forge tampering** | Retirement writes an immutable anchor the verifier resolves against | [TEST 5](scripts/verify-schema.sql) |
| **The chain survives a cache loss** | `audit_chain_head` is a table, advanced in-transaction | [TEST 6](scripts/verify-schema.sql) |
| **Two products cannot collide** | `realm` is the outermost key axis | [TEST 1](scripts/verify-schema.sql) |
| **Evidence outlives noise** | Per-severity retention windows; legal hold suspends retirement | [TEST 7](scripts/verify-schema.sql) |

`make verify-schema` applies the migrations to a throwaway PostgreSQL 16 and runs those assertions.
It also asserts that the *inherited* schema shape still fails to build, and fails loudly if it ever
stops failing.

## Using it

```go
rec, err := app.New(audit.Config{
    Realm:    "my-product",                  // required; isolates this product's key space
    StoreDSN: os.Getenv("AUDIT_PG_DSN"),
}, app.Deps{
    Sinks: sinks,                            // postgres by default; register more
    Chain: pg.NewChain(db),                  // durable head, in-transaction seal
})

rec.Record(ctx, audit.Entry{
    Tenant:   audit.Tenant{Kind: "workspace", ID: wsID},
    Actor:    audit.Actor{Kind: "agent", ID: userID, Role: "researcher"},
    Action:   "tool.search_workspace_knowledge",
    Subject:  audit.Subject{Type: "document", ID: docID},
    Severity: "info",
    IdemKey:  "run:" + runID + ":step:" + stepID,   // REQUIRED
})
```

A human action is the same call with `Actor{Kind: "user"}`. A sandbox execution is
`Actor{Kind: "sandbox"}`. None of them is a new table.

**`security` and `critical` entries always write synchronously**, whatever the durability setting —
a dropped security event is a compliance failure, so the performance knob does not apply to it.

## Documentation

| | |
|---|---|
| [ROADMAP.md](ROADMAP.md) | scope, phases, and when to use something else |
| [contracts/audit-ports.md](specs/001-audit-core/contracts/audit-ports.md) | every port, the invariants, contract tests |
| [design-decisions.md](specs/001-audit-core/design-decisions.md) | 15 decisions, each with what it prevents |
| [data-model.md](specs/001-audit-core/data-model.md) | tables, the chain, RLS, retention |
| [research.md](specs/001-audit-core/research.md) | the originating research, carried with its history |
| [docs/integration-guide.md](docs/integration-guide.md) | adopting it in a host |
| [docs/operations.md](docs/operations.md) | retention, anchors, verification, alarms |
| [docs/security.md](docs/security.md) | the threat model, stated precisely |
| [PROVENANCE.md](PROVENANCE.md) | where this came from and what changed |

## License

MIT — see [LICENSE](LICENSE).
