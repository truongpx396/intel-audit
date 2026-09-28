-- 0001_audit_core.sql — the append-only, tamper-evident audit trail.
--
-- Verified against PostgreSQL 16. Every unusual choice here is load-bearing; the
-- ones worth arguing about are in specs/001-audit-core/design-decisions.md.
--
-- Three nested isolation axes, all opaque to the engine:
--   realm   — WHICH PRODUCT. Outermost, so two products sharing a deployment
--             cannot collide in the idempotency key space (D1).
--   tenant  — the host's isolation boundary (workspace | organization | account).
--   actor   — WHO acted (user | agent | service | system | device | sandbox).
--
-- The engine never parses any of them.

BEGIN;

-- ---------------------------------------------------------------------------
-- audit_entry — one immutable, append-only record.
--
-- ONE table, not one per domain. A member action, an AI tool call and a sandbox
-- run differ only by actor_kind; adding an audited surface is a new value, never
-- a migration.
--
-- PARTITION BY RANGE (created_at) so retention is a partition retirement rather
-- than a row purge. The PK must carry created_at: PostgreSQL requires every
-- unique constraint on a partitioned table to include all partition-key columns.
-- That is exactly why the idempotency guard cannot live here -- see audit_idem.
-- ---------------------------------------------------------------------------
CREATE TABLE audit_entry (
    id           uuid        NOT NULL,
    realm        text        NOT NULL,
    tenant_kind  text        NOT NULL,
    tenant_id    text        NOT NULL,

    actor_kind   text        NOT NULL,
    actor_id     text        NOT NULL,
    -- Descriptive only. NEVER an authorization input: the trail records what a
    -- role was at the time, it does not decide anything (D14).
    actor_role   text        NOT NULL DEFAULT '',

    action       text        NOT NULL,
    subject_type text        NOT NULL DEFAULT '',
    subject_id   text        NOT NULL DEFAULT '',
    severity     text        NOT NULL DEFAULT 'info'
                             CHECK (severity IN ('info', 'notice', 'security', 'critical')),

    -- Audit detail: trace_id, token_cost, old -> new value. NEVER a payload dump.
    -- The no-body rule is enforced in the recorder AND re-checked sink-side (D8).
    attributes   jsonb       NOT NULL DEFAULT '{}'::jsonb,
    -- Fingerprint of a result/body that is deliberately NOT stored.
    result_hash  text,

    idem_key     text        NOT NULL,
    trace_id     text        NOT NULL DEFAULT '',

    -- Tamper-evidence: monotonic per (realm, tenant) sequence, linked by hash.
    seq          bigint      NOT NULL,
    prev_hash    text        NOT NULL DEFAULT '',
    entry_hash   text        NOT NULL,

    occurred_at  timestamptz NOT NULL DEFAULT now(),
    created_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

-- The chain read: walk one tenant's history in seq order.
CREATE INDEX audit_entry_chain_idx
    ON audit_entry (realm, tenant_kind, tenant_id, seq);
-- The console read: newest-first within a tenant, filterable.
CREATE INDEX audit_entry_list_idx
    ON audit_entry (realm, tenant_kind, tenant_id, created_at DESC);
-- "What happened to resource X" -- the cross-cutting query the inherited
-- two-table split made a painful UNION.
CREATE INDEX audit_entry_subject_idx
    ON audit_entry (realm, tenant_kind, tenant_id, subject_type, subject_id, created_at DESC);

CREATE TABLE audit_entry_2026m09 PARTITION OF audit_entry
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE audit_entry_2026m10 PARTITION OF audit_entry
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE audit_entry_2026m11 PARTITION OF audit_entry
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');

ALTER TABLE audit_entry ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_entry FORCE ROW LEVEL SECURITY;

CREATE POLICY audit_entry_tenant_scope ON audit_entry
    USING (
        realm       = current_setting('audit.realm', true)
    AND tenant_kind = current_setting('audit.tenant_kind', true)
    AND tenant_id   = current_setting('audit.tenant_id', true)
    );

-- ---------------------------------------------------------------------------
-- audit_idem — the exactly-once guard, deliberately NOT on audit_entry.
--
-- The inherited design required a durable UNIQUE (tenant, idem_key) on a table
-- partitioned by created_at. PostgreSQL forbids that pair. Adding created_at to
-- the constraint would satisfy Postgres and destroy the guarantee, because the
-- same key at a new timestamp becomes a new key. (D2)
-- ---------------------------------------------------------------------------
CREATE TABLE audit_idem (
    realm       text        NOT NULL,
    tenant_kind text        NOT NULL,
    tenant_id   text        NOT NULL,
    idem_key    text        NOT NULL,
    entry_id    uuid        NOT NULL,
    seq         bigint      NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (realm, tenant_kind, tenant_id, idem_key)
);

-- ---------------------------------------------------------------------------
-- audit_chain_head — the DURABLE per-tenant sequence head.
--
-- The inherited design called Redis "authoritative state" for this. It cannot
-- be: losing Redis restarts seq at 0, which either collides with existing rows
-- or leaves a permanent false break in the chain. The head is durable here and
-- advanced under a row lock in the same transaction as the append; Redis may
-- cache it, but is never the source of truth. (D4)
-- ---------------------------------------------------------------------------
CREATE TABLE audit_chain_head (
    realm       text        NOT NULL,
    tenant_kind text        NOT NULL,
    tenant_id   text        NOT NULL,
    last_seq    bigint      NOT NULL DEFAULT 0,
    last_hash   text        NOT NULL DEFAULT '',
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (realm, tenant_kind, tenant_id)
);

-- ---------------------------------------------------------------------------
-- audit_chain_anchor — what makes retention compatible with tamper-evidence.
--
-- THE contradiction in the inherited design: a seq gap is evidence of tampering
-- (invariant 6), and retention retires whole partitions (invariant 9). After one
-- retention run the chain starts at seq N with nothing before it -- which is
-- exactly what deletion looks like. Verify() would report tampering on a healthy
-- log, every time, forever.
--
-- Retiring a partition therefore writes an immutable anchor first, recording the
-- range it covered and the hash at its boundary. Verify() consults anchors, so a
-- retired range is PROVABLY retired rather than indistinguishable from deletion,
-- and the surviving chain still links back through the anchor's last_hash. (D3)
-- ---------------------------------------------------------------------------
CREATE TABLE audit_chain_anchor (
    id            uuid        PRIMARY KEY,
    realm         text        NOT NULL,
    tenant_kind   text        NOT NULL,
    tenant_id     text        NOT NULL,
    first_seq     bigint      NOT NULL,
    last_seq      bigint      NOT NULL,
    -- entry_hash of the LAST entry in the retired range: the surviving chain's
    -- first prev_hash must equal this, so the link survives the retirement.
    last_hash     text        NOT NULL,
    entry_count   bigint      NOT NULL,
    range_start   timestamptz NOT NULL,
    range_end     timestamptz NOT NULL,
    retired_at    timestamptz NOT NULL DEFAULT now(),
    retired_by    text        NOT NULL DEFAULT '',
    CHECK (last_seq >= first_seq),
    CHECK (range_end > range_start),
    UNIQUE (realm, tenant_kind, tenant_id, first_seq)
);

CREATE INDEX audit_chain_anchor_lookup_idx
    ON audit_chain_anchor (realm, tenant_kind, tenant_id, first_seq);

-- ---------------------------------------------------------------------------
-- audit_retention_policy — per-severity windows, and the legal-hold flag.
--
-- Severity tiers differ by a lot in practice: per-tool-call info telemetry is
-- noise after weeks, a security entry is evidence for years. One global window
-- forces the shortest acceptable retention on the most important rows.
--
-- hold_until suspends retirement for a tenant under investigation. Retiring a
-- partition during a dispute is a legal problem, not a housekeeping one.
-- ---------------------------------------------------------------------------
CREATE TABLE audit_retention_policy (
    realm        text        NOT NULL,
    tenant_kind  text        NOT NULL,
    tenant_id    text        NOT NULL,
    severity     text        NOT NULL
                             CHECK (severity IN ('info', 'notice', 'security', 'critical')),
    retention_window interval NOT NULL,
    hold_until   timestamptz,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (realm, tenant_kind, tenant_id, severity),
    CHECK (retention_window > interval '0')
);

-- ---------------------------------------------------------------------------
-- audit_sink_outbox — durable fan-out to additional sinks.
--
-- Invariant 8 asks for all-or-nothing fan-out across sinks, but Postgres and a
-- SIEM cannot share a transaction -- the same two-store problem metering and
-- notifications both solved with an outbox. Committing the entry and one outbox
-- row per extra sink in ONE transaction is what makes the guarantee real. (D6)
-- ---------------------------------------------------------------------------
CREATE TABLE audit_sink_outbox (
    id            uuid        PRIMARY KEY,
    entry_id      uuid        NOT NULL,
    realm         text        NOT NULL,
    tenant_kind   text        NOT NULL,
    tenant_id     text        NOT NULL,
    sink_kind     text        NOT NULL,
    attempts      int         NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    delivered_at  timestamptz,
    terminal_reason text      CHECK (terminal_reason IN ('max_attempts', 'sink_removed')),
    last_error    text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (entry_id, sink_kind)
);

CREATE INDEX audit_sink_outbox_claim_idx
    ON audit_sink_outbox (next_attempt_at)
    WHERE delivered_at IS NULL AND terminal_reason IS NULL;

COMMIT;
