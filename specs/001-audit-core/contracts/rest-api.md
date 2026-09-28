# Contract: REST surface

The investigator-facing surface — an admin console, a dispute, a SIEM export. Producers do **not** use
this; they use the `Recorder` port in-process or the gRPC facade.

Every route resolves `(realm, tenant)` from the authenticated session and sets the data-layer scope
for the transaction. **No route accepts a tenant id as a parameter** — that is what makes AR-014
enforceable rather than aspirational.

**The entire surface is read-only** except retention policy. There is no create, update or delete for
an entry anywhere, at any privilege level (AR-010).

## Reading the trail

| Method | Path | Purpose | Notes |
|---|---|---|---|
| GET | `/audit/entries` | List, newest first | `?actor_kind=&actor_id=&action=&severity=&since=&until=&limit=&cursor=` |
| GET | `/audit/entries/{id}` | One entry with its chain position | Returns `seq`, `prev_hash`, `entry_hash` |
| GET | `/audit/subjects/{type}/{id}` | Everything that happened to one resource | The query the inherited table-per-domain split made a `UNION` |
| GET | `/audit/export` | Bulk export for a SIEM or an auditor | Streaming NDJSON; paginated by `seq`, not offset, so a concurrent append cannot shift pages |

## Integrity

| Method | Path | Purpose | Notes |
|---|---|---|---|
| POST | `/audit/verify` | Verify a tenant's chain over a range | Body `{from, to}`. Returns the **range actually covered**, anchors traversed, and the first break if any ([D9](../design-decisions.md#d9)) |
| GET | `/audit/anchors` | List retirement anchors | How an investigator sees that a gap is retirement, not deletion |
| GET | `/audit/anchors/{first_seq}` | One anchor | `last_hash` is the link the surviving chain continues from |

`POST` is used for verify because the range can be large and verification is expensive; it is
nonetheless side-effect-free.

## Retention

| Method | Path | Purpose | Notes |
|---|---|---|---|
| GET | `/audit/retention` | Per-severity windows and any legal hold | |
| PUT | `/audit/retention` | Update windows | **Shortening a window is a privileged, audited action** — it is the one control that destroys evidence, so it writes a `security` entry about itself |
| POST | `/audit/retention/hold` | Place or lift a legal hold | Audited; a hold suspends retirement for the tenant |

## Error semantics

| Condition | Status | Body |
|---|---|---|
| Entry belongs to another tenant | `404` | Generic not-found — never distinguishes "exists but not yours" |
| Verify range crosses unanchored missing data | `200` | `{intact: false, detail: "seq_gap", break_seq: N}` — a real finding, not an error |
| Verify range is entirely retired | `200` | `{intact: true, covered: {...}, note: "range fully retired; resolved via anchors"}` |
| Retention window shortened below a legal hold | `409` | Names the hold and its expiry |
| Any attempt at a mutating verb on an entry | `405` | The surface has none |

## Observable assertions

- An investigator in tenant A never sees tenant B's entries, at any role (AS-001).
- Verification over a range spanning retired data reports intact, with anchors listed (AS-004).
- Verification of a tampered entry reports the first offending `seq` (AS-006).
- Shortening a retention window appears in the trail as its own `security` entry.
- Export paginated by `seq` returns every entry exactly once under concurrent appends.
