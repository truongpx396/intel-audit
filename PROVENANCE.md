# Provenance

`intel-audit` was extracted from
[**truongpx396/aisat-intel**](https://github.com/truongpx396/aisat-intel), where this engine was
designed as that product's audit backbone and deliberately factored for reuse. This file records
exactly what moved, what was generalized, and what was fixed — so any claim here can be checked
against the upstream repository.

Extracted at upstream `main` = `2f983a03f03b5232c66930aa8cb64b3e75020fb7` on 2026-09-28.

It is the fourth extraction from that project, after
[intel-agent](https://github.com/truongpx396/intel-agent),
[intel-payment](https://github.com/truongpx396/intel-payment) and
[intel-notification](https://github.com/truongpx396/intel-notification), and follows the same method:
carry the artifacts with their history, then resolve what the originating design left open.

---

## Files carried across **with their git history**

`git filter-repo` preserved the real commit history for every audit artifact. `git log --follow
<path>` here shows each one's evolution in the originating project.

**One file was dedicated to audit and came across whole:**

| This repository | Upstream path | Commits |
|---|---|---|
| `specs/001-audit-core/contracts/audit-ports.md` | `specs/001-contextengine-mvp/contracts/audit-ports.md` | 1 |

**Six were shared spec files covering the whole product**, where audit is one concern among many.
Carrying them whole would drag every commit about retrieval, agents, billing and notifications into
an audit repository. Instead each historical revision was **sliced to its audit content** during the
rewrite, so the commit lineage is genuinely the original file's while the content stays scoped:

| This repository | Commits | Slice |
|---|---|---|
| `specs/001-audit-core/tasks.md` | 22 | the audit tasks, and the audit clauses of the kernel-interface and schema tasks |
| `specs/001-audit-core/data-model.md` | 14 | the Audit Record and Sandbox Run Record entities, RLS and retention rules |
| `specs/001-audit-core/research.md` | 11 | the audit, tamper-evidence, retention and no-body decisions |
| `specs/001-audit-core/spec.md` | 10 | FR-023, FR-024 and the audit edge cases |
| `specs/001-audit-core/plan.md` | 7 | technical context and the kernel layout |
| `specs/001-audit-core/quickstart.md` | 1 | the audit verification steps |

Selection was by **keyword match, not fixed section numbers**, because numbering moves across 193
upstream commits — matching on content lets the slice track each file as it evolved rather than going
blank when a heading was renumbered. Commits touching no audit content became empty and were pruned,
which is why **52 commits reach this repository's root** out of 193 upstream. The slicer is kept
at `scripts/auditslice.py` so the rewrite is reproducible.

The tip of each shared file is **not** its slice: a generalization commit replaces `spec.md`,
`plan.md`, `tasks.md`, `data-model.md` and `quickstart.md` with versions rewritten for this
repository. The slice is what the *history* shows; the rewrite is what you read. `research.md` keeps
its sliced content, generalized in place, because the research is the originating project's work and
is credited as such.

---

## Generalization applied

- **Host vocabulary removed** — `workspace_id` became the opaque `(realm, tenant_kind, tenant_id)`
  triple; `actor_type`/`agent_role` folded into one `Actor{Kind, ID, Role}`; the product's name
  became "the originating product".
- **Three tables became one** — `audit_log`, `agent_audit_log` and `sandbox_run` are one
  `audit_entry` discriminated by `actor_kind` (D14). The originating design already described this as
  the target; here it is the schema.
- **Redis demoted from required to optional** — it cached the chain head and was described as
  authoritative for it. It is now advisory, and PostgreSQL is the only required infrastructure (D4).
- **Requirement ids remapped** — `FR-023`/`FR-024` to `AR-0NN`, success criteria to `AS-0NN`.
- **"The seam is the follow-up" became "this repository is the follow-up"** — the originating contract
  closed by admitting audit had no implementation task. That admission is now resolved text.

## Design work added during the lift

15 decisions in [design-decisions.md](specs/001-audit-core/design-decisions.md). Four change behaviour rather than
presentation, and all four were found by **applying** the schema rather than reading it:

| # | Finding | Why it mattered |
|---|---|---|
| **D2** | The idempotency constraint **cannot be created** | Invariant 4 required a durable `UNIQUE (tenant, idem_key)`; invariant 9 required `PARTITION BY RANGE (created_at)`. PostgreSQL rejects the pair, and that index is the exactly-once backstop |
| **D3** | Retention and tamper-evidence **contradict each other** | Invariant 6 treats a sequence gap as tampering; invariant 9 retires whole partitions. After one retention run a healthy log reports tampering — forever, on every tenant |
| **D4** | The chain head was a **cache** | The data model names Redis "authoritative state" for the per-tenant head. Losing it restarts the sequence, producing a collision or a permanent false break no replay can repair |
| **D15** | Append-only was **only an API shape** | "The surface exposes no update or delete method" constrains the application and nothing else — not a `psql` session, and not the attacker the trail exists to catch |

### D2, in context

This is the **third** subsystem of the originating design to carry the unconstructible
partitioned-plus-unique pattern, after `credit_ledger`
([intel-payment](https://github.com/truongpx396/intel-payment)) and `notifications`
([intel-notification](https://github.com/truongpx396/intel-notification)). One shape was copied
across three specifications and applied in none of them. That is a process finding rather than three
coincidences: a schema nobody runs is prose.

### D3, in context

D3 is the one worth reading even if you never adopt this engine. The two invariants are individually
reasonable and jointly impossible, and the failure is not a false alarm you learn to live with — a
system that cries tampering every month trains its operators to dismiss the alarm, so the one real
tampering event is dismissed with the rest. Demonstrated:

```
before retention  seq: 1,2,3,4
after  retention  seq: 3,4
=> Verify() sees the chain starting at seq 3 with no seq 1..2 --
   indistinguishable from deletion, i.e. it reports TAMPERING on a healthy log
```

---

## What this repository does **not** take

Deliberately left in the originating project:

- Retrieval, ingestion, the LLM gateway, the agent runtime, sandboxing.
- Metering, notifications and the approval gate — extracted separately, or still that product's.
- That product's requirements, success criteria and roadmap.
- The admin console's audit-log screen: it is that product's UI, and this repository specifies the
  REST surface rather than a design system.

## Relationship going forward

The two repositories are independent. `aisat-intel` points here as the canonical home for the audit
design and keeps a binding note; this repository does not depend on it.

Where the two disagree, **this repository is authoritative** for the audit, chain, sink and retention
contracts.
