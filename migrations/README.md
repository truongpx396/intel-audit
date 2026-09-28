# Migrations

Applied in filename order. Verified against **PostgreSQL 16** by `make verify-schema`, which runs them
against a throwaway container and asserts the guarantees they are meant to provide.

| File | Contents |
|---|---|
| `0001_audit_core.sql` | `audit_entry` (partitioned, RLS forced), `audit_idem`, `audit_chain_head`, `audit_chain_anchor`, `audit_retention_policy`, `audit_sink_outbox` |
| `0002_append_only.sql` | Mutation-rejecting trigger + least-privilege grants |

## Why the schema looks the way it does

Four choices are counterintuitive and each is load-bearing. Full reasoning in
[design-decisions.md](../specs/001-audit-core/design-decisions.md):

- **The idempotency guard is a separate table.** A unique index on `(tenant, idem_key)` **cannot be
  created** on a table partitioned by `created_at` ([D2](../specs/001-audit-core/design-decisions.md#d2)).
- **The chain head is a table, not a cache key.** Losing it must not restart the sequence
  ([D4](../specs/001-audit-core/design-decisions.md#d4)).
- **Retirement writes an anchor first.** Otherwise retention makes verification report tampering on a
  healthy log, permanently ([D3](../specs/001-audit-core/design-decisions.md#d3)).
- **A trigger enforces append-only.** The absence of an `UPDATE` method is not a constraint
  ([D15](../specs/001-audit-core/design-decisions.md#d15)).

## Partitions

`audit_entry` is `PARTITION BY RANGE (created_at)`. The bootstrap migration creates three months;
provisioning further months is an operator responsibility.

There is deliberately **no default partition**: a missing partition fails an insert loudly, which is
recoverable, while a default partition silently absorbs rows and can never be retired.

## Adding a migration

1. Sequential filename, `NNNN_description.sql`.
2. Wrap in `BEGIN` / `COMMIT`.
3. Comment *why*, not what.
4. Add an assertion to `scripts/verify-schema.sql` for any new guarantee.
5. **Never add an `UPDATE` or `DELETE` path to an append-only table.** If you believe you need one,
   that is a design discussion, not a migration.
