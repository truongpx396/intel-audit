-- seed.sql — a small, readable dataset for local development.
--
-- Shapes chosen to make the interesting properties visible immediately: two
-- tenants in one realm plus a second realm reusing an identical idem_key, three
-- actor kinds in one table, and an anchor so a verifier can be exercised across
-- a retirement boundary without waiting for retention to run.
--
-- Apply AFTER the migrations:
--   psql "$AUDIT_PG_DSN" -f scripts/seed.sql

BEGIN;

INSERT INTO audit_entry (id, realm, tenant_kind, tenant_id, actor_kind, actor_id, actor_role,
                         action, subject_type, subject_id, severity, attributes, result_hash,
                         idem_key, trace_id, seq, prev_hash, entry_hash, created_at)
VALUES
 ('018f2000-0000-7000-8000-000000000001','local','workspace','w1','user','u1','admin',
  'member.invited','invite','i1','security','{}','', 'invite:i1:created','t1',
  3,'anchored-h2','h3', now()),

 ('018f2000-0000-7000-8000-000000000002','local','workspace','w1','agent','u1','researcher',
  'tool.search_workspace_knowledge','document','d1','info',
  '{"token_cost":"1420","trace_id":"t2"}','sha256:9f2b…','run:r1:step:s1','t2',
  4,'h3','h4', now()),

 ('018f2000-0000-7000-8000-000000000003','local','workspace','w1','sandbox','u1','',
  'sandbox.convert','document','d1','notice','{"exit":"0","egress_bytes":"0"}','sha256:aa10…',
  'sandbox:run:9','t3', 5,'h4','h5', now()),

 -- a different tenant: must never be visible to w1
 ('018f2000-0000-7000-8000-000000000004','local','workspace','w2','user','u9','member',
  'member.invited','invite','i1','security','{}','', 'invite:i1:created','t4',
  1,'','k1', now()),

 -- a different realm reusing an identical idem_key on purpose (D1)
 ('018f2000-0000-7000-8000-000000000005','other-product','workspace','w1','user','u1','admin',
  'member.invited','invite','i1','security','{}','', 'invite:i1:created','t5',
  1,'','m1', now());

INSERT INTO audit_idem (realm, tenant_kind, tenant_id, idem_key, entry_id, seq) VALUES
 ('local','workspace','w1','invite:i1:created','018f2000-0000-7000-8000-000000000001',3),
 ('local','workspace','w1','run:r1:step:s1','018f2000-0000-7000-8000-000000000002',4),
 ('local','workspace','w1','sandbox:run:9','018f2000-0000-7000-8000-000000000003',5),
 ('local','workspace','w2','invite:i1:created','018f2000-0000-7000-8000-000000000004',1),
 ('other-product','workspace','w1','invite:i1:created','018f2000-0000-7000-8000-000000000005',1);

INSERT INTO audit_chain_head (realm, tenant_kind, tenant_id, last_seq, last_hash) VALUES
 ('local','workspace','w1',5,'h5'),
 ('local','workspace','w2',1,'k1'),
 ('other-product','workspace','w1',1,'m1');

-- w1's seq starts at 3 because 1..2 were retired. WITHOUT this anchor that gap is
-- indistinguishable from deletion and Verify() reports tampering (D3).
INSERT INTO audit_chain_anchor (id, realm, tenant_kind, tenant_id, first_seq, last_seq,
                                last_hash, entry_count, range_start, range_end, retired_by)
VALUES ('018f2000-0000-7000-8000-0000000000a1','local','workspace','w1',1,2,'anchored-h2',2,
        now() - interval '120 days', now() - interval '90 days','retention.tick');

INSERT INTO audit_retention_policy (realm, tenant_kind, tenant_id, severity, retention_window) VALUES
 ('local','workspace','w1','info',     interval '30 days'),
 ('local','workspace','w1','notice',   interval '90 days'),
 ('local','workspace','w1','security', interval '7 years'),
 ('local','workspace','w1','critical', interval '7 years');

COMMIT;
