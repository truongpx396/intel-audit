-- 0002_append_only.sql — make append-only a DATABASE guarantee, not an API shape.
--
-- Verified against PostgreSQL 16.
--
-- The inherited contract says "the audit surface exposes no update or delete
-- method". True, and insufficient: absence of a method in Go stops the
-- application, not a psql session, an ORM, a migration script, or anyone with
-- the connection string. An audit trail whose immutability rests on nobody
-- calling the wrong function is not immutable -- and it is exactly the trail an
-- attacker with database access edits.
--
-- So the constraint moves into the database (D15). Two layers, because either
-- alone is bypassable:
--   1. A trigger that raises on UPDATE or DELETE.
--   2. Revoked table privileges for the application role.
-- Retirement of an aged partition stays possible, because that is a DDL
-- operation on a partition and not a row mutation.

BEGIN;

CREATE OR REPLACE FUNCTION audit_reject_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    -- Deliberately table-agnostic: this guards every append-only relation, and
    -- they do not share a column set. Referencing OLD.<column> here would make
    -- the guard itself a source of errors on the tables it is meant to protect.
    RAISE EXCEPTION 'relation %.% is append-only: % is not permitted',
        TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP
      USING HINT = 'Retention retires whole partitions and records an anchor; '
                   'it never mutates rows. See design-decisions.md D3 and D15.',
            ERRCODE = 'restrict_violation';
END;
$$;

-- Row triggers propagate to every partition, including ones created later.
CREATE TRIGGER audit_entry_append_only
    BEFORE UPDATE OR DELETE ON audit_entry
    FOR EACH ROW EXECUTE FUNCTION audit_reject_mutation();

-- The chain metadata is equally evidence: an anchor that can be rewritten lets a
-- retired range be re-described, which defeats the point of anchoring it.
CREATE TRIGGER audit_chain_anchor_append_only
    BEFORE UPDATE OR DELETE ON audit_chain_anchor
    FOR EACH ROW EXECUTE FUNCTION audit_reject_mutation();

-- Second layer: the application role gets INSERT and SELECT, nothing else.
-- Created here so a deployment that forgets to provision roles still gets the
-- trigger; a deployment that does provision them gets both.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'audit_writer') THEN
        CREATE ROLE audit_writer NOLOGIN;
    END IF;
END $$;

REVOKE ALL ON audit_entry        FROM audit_writer;
REVOKE ALL ON audit_chain_anchor FROM audit_writer;
GRANT  SELECT, INSERT ON audit_entry        TO audit_writer;
GRANT  SELECT, INSERT ON audit_chain_anchor TO audit_writer;
GRANT  SELECT, INSERT, UPDATE ON audit_chain_head TO audit_writer;  -- the head advances by design
GRANT  SELECT, INSERT ON audit_idem TO audit_writer;
GRANT  SELECT, INSERT, UPDATE ON audit_sink_outbox TO audit_writer; -- delivery state advances

COMMIT;
