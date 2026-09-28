# Tasks (Phase 2)

**Not started.** Depends on [Phase 1](../001-audit-core/tasks.md) Stages 1–6. Sketched at the
granularity needed to judge scope, not to execute.

## Stage 1 — Anchor port and publication

- [ ] **T101** `ports/anchor.go`: `Anchor{Publish(head) → Proof, Fetch(seq) → Proof}` (AR-101)
- [ ] **T102** Migration: `audit_anchor_publication` — the head published, the proof, the external
      reference, the attempt state
- [ ] **T103** [P] `adapters/driven/anchor/rfc3161`: timestamp-authority anchor, no counterparty (AR-102)
- [ ] **T104** [P] `adapters/driven/anchor/transparencylog`
- [ ] **T105** Scheduled publisher with resumability across outages (AR-106)
- [ ] **T106** Publication recorded as an audit entry (AR-103)
- [ ] **T107** Alarm on publication failure; the unanchored tail is always reported (AR-105, AS-102)

## Stage 2 — Independent verification

- [ ] **T108** Bundle format: entries, chain metadata, anchors, external proofs (AR-107)
- [ ] **T109** `cmd/audit-verify`: standalone, **no database dependency** (AR-108)
- [ ] **T110** The bundle states what it proves and what it does not, including the tail (AR-109)
- [ ] **T111** Contract test AS-101: a forged history produced by an adversary who controlled the
      database is still detected from bundle + public anchor. This is the test the phase exists for
- [ ] **T112** Contract test AS-103: the standalone verifier agrees with the engine on intact and
      tampered bundles

## Stage 3 — Legal hold

- [ ] **T113** Hold placement/lift as audited entries with authorizing actor (AR-111)
- [ ] **T114** Retention honours holds, including mid-run (AR-110, AS-104)
- [ ] **T115** A hold placed after retirement surfaces the anchor for the retired range (AR-112)
- [ ] **T116** Contract test: retention mid-run cannot race a hold into retiring held data
