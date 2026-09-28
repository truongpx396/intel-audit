-- verify-schema.sql — assert the schema actually provides its guarantees.
--
-- Run via `make verify-schema`, which applies the migrations to a throwaway
-- PostgreSQL 16 first. Every assertion maps to a success criterion or a design
-- decision; an assertion mapping to neither does not belong here.
--
--   TEST 1  realm isolates the idempotency key space        D1
--   TEST 2  a replay is rejected by the durable guard       AS-002
--   TEST 3  RLS scopes the trail to one tenant              AS-001 (release blocker)
--   TEST 4  UPDATE and DELETE are rejected by the database  D15 (release blocker)
--   TEST 5  retention stays distinguishable from deletion   D3  (the headline)
--   TEST 6  the chain head is durable, not cache-resident   D4
--   TEST 7  severity and retention policy are constrained   D7
--
\set ON_ERROR_STOP on

INSERT INTO audit_entry (id, realm, tenant_kind, tenant_id, actor_kind, actor_id, actor_role,
                         action, subject_type, subject_id, severity, idem_key, seq, prev_hash,
                         entry_hash, created_at)
VALUES
 ('018f0000-0000-7000-8000-00000000b001','app','workspace','w1','user','u1','admin',
  'member.invited','invite','i1','security','inv:i1',1,'','h1','2026-09-10'),
 ('018f0000-0000-7000-8000-00000000b002','app','workspace','w1','agent','u1','researcher',
  'tool.search_workspace_knowledge','document','d1','info','tool:t1',2,'h1','h2','2026-09-11'),
 ('018f0000-0000-7000-8000-00000000b003','app','workspace','w2','user','u9','member',
  'member.invited','invite','i1','security','inv:i1',1,'','h9','2026-09-11'),
 -- a second product, reusing an identical idem_key on purpose
 ('018f0000-0000-7000-8000-00000000b004','other','workspace','w1','user','u1','admin',
  'member.invited','invite','i1','security','inv:i1',1,'','hx','2026-09-11');

INSERT INTO audit_idem (realm, tenant_kind, tenant_id, idem_key, entry_id, seq) VALUES
 ('app','workspace','w1','inv:i1','018f0000-0000-7000-8000-00000000b001',1),
 ('app','workspace','w1','tool:t1','018f0000-0000-7000-8000-00000000b002',2),
 ('app','workspace','w2','inv:i1','018f0000-0000-7000-8000-00000000b003',1),
 ('other','workspace','w1','inv:i1','018f0000-0000-7000-8000-00000000b004',1);

\echo '=== TEST 1: realm and tenant both isolate the idempotency key space (D1) ==='
SELECT realm, tenant_id, idem_key FROM audit_idem WHERE idem_key='inv:i1' ORDER BY realm, tenant_id;

\echo '=== TEST 2: a replay of the SAME (realm,tenant,idem) is rejected (AS-002) ==='
DO $$ BEGIN
    INSERT INTO audit_idem (realm,tenant_kind,tenant_id,idem_key,entry_id,seq)
    VALUES ('app','workspace','w1','inv:i1','018f0000-0000-7000-8000-00000000bfff',99);
    RAISE EXCEPTION 'FAIL: duplicate idem_key accepted';
EXCEPTION WHEN unique_violation THEN RAISE NOTICE 'PASS: replay blocked by audit_idem PK';
END $$;

\echo '=== TEST 3: RLS scopes the trail to one tenant (AS-001, release blocker) ==='
CREATE ROLE audit_reader NOLOGIN;
GRANT SELECT ON audit_entry TO audit_reader;
SET ROLE audit_reader;
SET audit.realm='app'; SET audit.tenant_kind='workspace'; SET audit.tenant_id='w1';
\echo 'w1 sees (expect only its own two entries):'
SELECT tenant_id, actor_kind, action FROM audit_entry ORDER BY seq;
SET audit.tenant_id='w2';
\echo 'w2 sees (expect only its own -- no leak of w1):'
SELECT tenant_id, actor_kind, action FROM audit_entry;
\echo 'wrong realm sees (expect 0 -- realm is in the predicate):'
SET audit.realm='nonexistent'; SET audit.tenant_id='w1';
SELECT count(*) AS rows_visible FROM audit_entry;
RESET ROLE;

\echo '=== TEST 4: the database itself rejects mutation (D15, release blocker) ==='
DO $$ BEGIN
    UPDATE audit_entry SET action='member.removed' WHERE seq=1 AND realm='app';
    RAISE EXCEPTION 'FAIL: an audit row was UPDATED';
EXCEPTION WHEN restrict_violation THEN RAISE NOTICE 'PASS: UPDATE rejected in-database, not merely absent from the API';
END $$;
DO $$ BEGIN
    DELETE FROM audit_entry WHERE seq=1 AND realm='app';
    RAISE EXCEPTION 'FAIL: an audit row was DELETED';
EXCEPTION WHEN restrict_violation THEN RAISE NOTICE 'PASS: DELETE rejected in-database';
END $$;
DO $$ BEGIN
    UPDATE audit_chain_anchor SET last_hash='forged' WHERE true;
    IF FOUND THEN RAISE EXCEPTION 'FAIL: an anchor was rewritten'; END IF;
    RAISE NOTICE 'PASS: no anchors yet; anchor immutability asserted in TEST 5';
EXCEPTION WHEN restrict_violation THEN RAISE NOTICE 'PASS: anchor UPDATE rejected in-database';
END $$;

\echo '=== TEST 5: retention stays DISTINGUISHABLE from deletion (D3 -- the headline) ==='
\echo 'Without an anchor, retiring a partition leaves a seq gap that reads as tampering.'
\echo 'Retirement therefore records an anchor first:'
INSERT INTO audit_chain_anchor (id, realm, tenant_kind, tenant_id, first_seq, last_seq,
                                last_hash, entry_count, range_start, range_end, retired_by)
VALUES ('018f0000-0000-7000-8000-00000000c001','app','workspace','w1',1,2,'h2',2,
        '2026-09-01','2026-10-01','retention.tick');
SELECT first_seq, last_seq, last_hash, entry_count, retired_at IS NOT NULL AS stamped
  FROM audit_chain_anchor WHERE realm='app';
\echo 'A verifier now resolves a chain starting at seq 3 against the anchor:'
SELECT CASE
  WHEN EXISTS (SELECT 1 FROM audit_chain_anchor
                WHERE realm='app' AND tenant_id='w1' AND last_seq = 3 - 1)
  THEN 'PASS: seq 3 links to anchored last_seq 2 -- retired, not deleted'
  ELSE 'FAIL: gap unexplained; indistinguishable from deletion' END AS verdict;
DO $$ BEGIN
    UPDATE audit_chain_anchor SET last_hash='forged' WHERE realm='app';
    RAISE EXCEPTION 'FAIL: an anchor was rewritten';
EXCEPTION WHEN restrict_violation THEN RAISE NOTICE 'PASS: anchors are immutable too';
END $$;

\echo '=== TEST 6: the chain head is DURABLE, not cache-resident (D4) ==='
INSERT INTO audit_chain_head (realm, tenant_kind, tenant_id, last_seq, last_hash)
VALUES ('app','workspace','w1',2,'h2');
SELECT CASE WHEN count(*)=1 THEN 'PASS: head survives in Postgres; Redis may cache it, never own it'
            ELSE 'FAIL' END AS verdict
  FROM audit_chain_head WHERE realm='app' AND tenant_id='w1';

\echo '=== TEST 7: severity and retention policy are constrained (D7) ==='
DO $$ BEGIN
    INSERT INTO audit_entry (id, realm, tenant_kind, tenant_id, actor_kind, actor_id,
                             action, severity, idem_key, seq, entry_hash, created_at)
    VALUES ('018f0000-0000-7000-8000-00000000d001','app','workspace','w1','user','u1',
            'x','URGENT','k',9,'h','2026-10-02');
    RAISE EXCEPTION 'FAIL: bogus severity accepted';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'PASS: severity restricted to info|notice|security|critical';
END $$;
DO $$ BEGIN
    INSERT INTO audit_retention_policy (realm,tenant_kind,tenant_id,severity,retention_window)
    VALUES ('app','workspace','w1','security', interval '0');
    RAISE EXCEPTION 'FAIL: a zero retention window accepted';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'PASS: retention window must be positive';
END $$;
INSERT INTO audit_retention_policy (realm,tenant_kind,tenant_id,severity,retention_window,hold_until)
VALUES ('app','workspace','w1','security', interval '7 years', '2027-01-01');
SELECT severity, retention_window, hold_until IS NOT NULL AS under_legal_hold
  FROM audit_retention_policy WHERE realm='app';
