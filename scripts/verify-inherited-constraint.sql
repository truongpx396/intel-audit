-- verify-inherited-constraint.sql — demonstrate that the INHERITED audit_log shape
-- cannot be constructed, so D2 is a finding rather than an opinion.
--
-- The originating design required BOTH a durable UNIQUE (tenant, idem_key)
-- (invariant 4, the exactly-once backstop) AND PARTITION BY RANGE (created_at)
-- (invariant 9, bounded growth). PostgreSQL rejects the combination.
--
-- This script is EXPECTED TO FAIL, with that specific error. `make verify-schema`
-- asserts the failure AND its reason, and fails the build if either changes.

CREATE TABLE audit_log_inherited (
    id           uuid        NOT NULL,
    workspace_id uuid        NOT NULL,
    action       text        NOT NULL,
    idem_key     text        NOT NULL,
    seq          bigint      NOT NULL,
    entry_hash   text        NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, idem_key)
) PARTITION BY RANGE (created_at);
