# Implementation plan

**Spec**: [spec.md](spec.md) · **Contracts**: [contracts/](contracts/) · **Build order**: [tasks.md](tasks.md)

## Technical context

| | |
|---|---|
| **Language** | Go 1.24 |
| **Module** | `github.com/truongpx396/intel-audit` |
| **Store** | PostgreSQL 16 (durable; the only required infrastructure) |
| **Cache** | Redis 7, **optional and advisory** — it may cache the chain head, never own it ([D4](design-decisions.md#d4)) |
| **Transports** | in-process (library) and gRPC (service) — both satisfy `Recorder` |
| **Testing** | table-driven contract suites; Testcontainers behind `//go:build integration` |
| **Lint** | `go-arch-lint` for the component graph, `golangci-lint` + `depguard` for banned imports |

Dropping Redis from the required set is a deliberate reduction from the originating design, which
made it authoritative for the chain head. See [D4](design-decisions.md#d4) for why that could not
stand.

## Architecture

Ports and adapters, dependency rule `adapters → app → ports → domain`, enforced in CI:

```text
domain/      Realm · Tenant · Actor · Action · Subject · Entry · Sealed · Receipt
             canonical.go — the specified hash input form (D12)
ports/       driving.go (Recorder, Verifier) · driven.go (Sink, SinkRegistry,
             HashChain, AuditQuery, Clock, IDs)
app/         record · batch · seal · redact · verify · retention · fanout
adapters/
  driven/    postgres/ (sink, chain, query, anchors) · redis/ (advisory head cache)
             sink/ (kafka · s3append · splunk — added here)
  driving/   inprocess/ · grpcserver/ · grpcclient/
migrations/  owns the schema
config.go    the entire configuration surface
```

The originating contract closed with an honest note: audit was *"the one backbone in this system that
is production-correct but not yet behind its reusable seam — this document is the seam; the tasks are
the follow-up."* This repository is that follow-up.

## Phasing

| Stage | Delivers | Verifiable by |
|---|---|---|
| **1. Schema** | migrations + assertions | The seven schema assertions pass against PostgreSQL 16 |
| **2. Domain + ports** | types, interfaces, **canonical form**, config | `canonical()` golden-vector tests; config validation |
| **3. Chain** | durable head, in-transaction seal, verify | Contiguity, linkage, determinism, tamper detection |
| **4. Postgres sink** | append, batch, idempotency, query | `SinkContract`; the RLS leak suite |
| **5. Recorder** | redact → seal → append in one transaction | `RecorderContract`; replay, no-body, sync-for-security |
| **6. Retention + anchors** | retire a range, record its anchor, verify across it | **AS-004**: verification intact after retention |
| **7. Fan-out** | outbox + additional sinks | A failing secondary sink never loses an entry |
| **8. Transports** | gRPC server + client as `Recorder` | Same contract suite over the wire |
| **9. Boundary gates** | arch-lint, depguard, no-host build | CI fails on an inbound host import |

Stages 1–6 are the minimum satisfying AS-001 through AS-005 — the release blockers. Note that
**stage 6 is not optional polish**: without anchors, retention makes verification report tampering, so
a deployment running stages 1–5 plus retention is worse than one with no verification at all.

## Risks

| Risk | Mitigation |
|---|---|
| Canonical form drifts between implementations or library versions | It is specified in the contract and pinned by golden vectors; a change to it is a breaking change to verification ([D12](design-decisions.md#d12)) |
| The chain head becomes a write bottleneck under load | The head is per `(realm, tenant)`, so contention is per tenant; batching amortizes it ([D11](design-decisions.md#d11)) |
| Someone adds an `UPDATE` path for "just this one fix" | The database rejects it; changing that is a migration and a review ([D15](design-decisions.md#d15)) |
| A secondary sink outage silently drops the compliance backhaul | Fan-out is an outbox with attempt caps and alarms ([D6](design-decisions.md#d6)) |
| Buffering corrupts the chain | Buffered entries are unsealed; sequence is assigned at durable append ([D5](design-decisions.md#d5)) |
| Operators trust "tamper-proof" | The README and ROADMAP say tamper-**evident**, and name exactly who it does not defend against |

## Out of scope

Everything in [ROADMAP.md § What this is not](../../ROADMAP.md#what-this-is-not). Most consequential:
defending against a privileged operator needs [Phase 2](../002-anchoring-legal-hold/) external
anchoring, and auditing *reads* of the trail is Phase 3 and undesigned.
