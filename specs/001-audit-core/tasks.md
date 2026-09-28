# Tasks

Dependency-ordered build order. `[P]` marks tasks that can run in parallel with their siblings. Each
names the requirement it satisfies; a task naming none is scope creep.

Stages map to [plan.md § Phasing](plan.md#phasing). Stages 1–6 are the release-blocking core — and
stage 6 in particular is not optional, because retention without anchors actively breaks verification.

---

## Stage 1 — Schema

- [x] **T001** `migrations/0001_audit_core.sql`: `audit_entry` (partitioned, RLS forced), `audit_idem`,
      `audit_chain_head`, `audit_chain_anchor`, `audit_retention_policy`, `audit_sink_outbox`
      (AR-001, AR-003, AR-007, AR-012, AR-014)
- [x] **T002** `migrations/0002_append_only.sql`: mutation-rejecting trigger + least-privilege grants
      (AR-010, [D15](design-decisions.md#d15))
- [x] **T003** `scripts/verify-schema.sql` + `make verify-schema`: seven assertions, including that
      the inherited shape still fails for its documented reason (AS-001, AS-002, AS-003)
- [ ] **T004** `migrations/0003_partition_provisioning.sql`: provision the next N months; alarm on a
      missing partition (AR-011)

## Stage 2 — Domain, ports, canonical form

- [ ] **T005** `domain/`: `Realm`, `Tenant`, `Actor`, `Action`, `Subject`, `Severity`, `Entry`,
      `Sealed`, `Receipt`, `VerifyReport`. Imports nothing outside the module
- [ ] **T006** `domain/canonical.go` + **golden vectors**: the specified canonical form — UTF-8 JSON,
      sorted keys, RFC 3339 UTC ms, omitted optionals. A frozen vector table is the regression guard
      ([D12](design-decisions.md#d12), AR-008)
- [ ] **T007** [P] `ports/driving.go`: `Recorder`, `Verifier`
- [ ] **T008** [P] `ports/driven.go`: `Sink`, `SinkRegistry`, `HashChain`, `AuditQuery`, `Clock`, `IDSource`
- [ ] **T009** `config.go`: `Realm` required with no default; per-severity retention; durability mode
      (AR-015, [D1](design-decisions.md#d1))

## Stage 3 — The chain

- [ ] **T010** `adapters/driven/postgres/chain.go`: next sequence via `SELECT … FOR UPDATE` on the
      durable head, inside the append transaction (AR-007, [D10](design-decisions.md#d10))
- [ ] **T011** `app/seal.go`: `Seal` pure over `(prev_hash, canonical(entry), seq)` (AR-008)
- [ ] **T012** `app/verify.go`: walk a range, resolve anchors, report the covered range (AR-009,
      [D9](design-decisions.md#d9))
- [ ] **T013** [P] `adapters/driven/redis/headcache.go`: advisory cache; a miss reads Postgres, a
      stale value is never trusted for sealing ([D4](design-decisions.md#d4))
- [ ] **T014** **Contract test** `HashChainContract`: contiguity, linkage, determinism, tamper
      detection, and **cache-loss recovery** (AS-005, AS-006)

## Stage 4 — Postgres sink

- [ ] **T015** `adapters/driven/postgres/sink.go`: `Append` idempotent on `(realm, tenant, idem_key)`
      (AR-003)
- [ ] **T016** `AppendBatch`: N entries, contiguous sequences, one transaction (AR-004,
      [D11](design-decisions.md#d11))
- [ ] **T017** No-body re-check before append — the sink does not trust the recorder (AR-016,
      [D8](design-decisions.md#d8))
- [ ] **T018** `adapters/driven/postgres/query.go`: `List`, `BySubject`, tenant-scoped, paginated
- [ ] **T019** **Contract test** `SinkContract` + the RLS leak suite, run **as the owning role**
      because that is the role the application uses (AS-001, release blocker)

## Stage 5 — Recorder

- [ ] **T020** `app/redact.go`: pure, applied before sealing so the hash covers the redacted form
      (AR-016)
- [ ] **T021** `app/record.go`: redact → seal → append in one transaction (AR-001, AR-003)
- [ ] **T022** Durability modes; `security`/`critical` always synchronous, buffered entries held
      **unsealed** (AR-005, [D5](design-decisions.md#d5))
- [ ] **T023** **Contract test** `RecorderContract`: replay is a no-op, no-body holds against
      adversarial attributes, a security entry is durable before ack (AS-002, AS-007)

## Stage 6 — Retention and anchors *(not optional)*

- [ ] **T024** `app/retention.go`: select a retirable range per severity, honouring legal hold (AR-013)
- [ ] **T025** **Write the anchor, then retire** — never the reverse; a crash between them must leave
      a retirable range, not an unexplained gap (AR-012, [D3](design-decisions.md#d3))
- [ ] **T026** `Verify` resolves retired ranges through anchors
- [ ] **T027** **Contract test** AS-004: a log that has undergone several retention runs still
      verifies intact. This is the test that distinguishes this engine from the design it came from

## Stage 7 — Fan-out

- [ ] **T028** `app/fanout.go`: primary append + one outbox row per additional sink, one transaction
      (AR-019, [D6](design-decisions.md#d6))
- [ ] **T029** Drainer with attempt caps, alarms and a terminal state
- [ ] **T030** [P] A second reference sink to prove AR-018 costs one file plus one registration (AS-008)

## Stage 8 — Transports

- [ ] **T031** `adapters/driving/inprocess`
- [ ] **T032** [P] `api/auditv1` proto + `grpcserver` + `grpcclient`, the client satisfying `Recorder`
      with a compile-time assertion (AR-020)
- [ ] **T033** Run `RecorderContract` over gRPC — identical semantics is the claim, so it gets the
      identical suite

## Stage 9 — Boundary gates

- [ ] **T034** `.go-arch-lint.yml` component graph; `.golangci.yml` depguard bans (AR-020)
- [ ] **T035** CI job building and testing with **no host present** (AS-009)
- [ ] **T036** CI job running `make verify-schema` on every migration change

## Stage 10 — Release

- [ ] **T037** [P] Fill `docs/integration-guide.md` samples against the built API
- [ ] **T038** [P] `docs/operations.md`: retention runbook, anchor inspection, verification on demand
- [ ] **T039** Tag `v0.1.0` once Stages 1–6 are green

---

## Not in this phase

External anchoring, operator-proof integrity, third-party attestation and legal-hold mechanics against
anchored ranges are [Phase 2](../002-anchoring-legal-hold/). Auditing reads of the trail is Phase 3
and undesigned. See [ROADMAP.md](../../ROADMAP.md).
