# Security

An audit trail's threat model deserves stating precisely, because the failure mode is a confident
answer to a question the system cannot actually answer.

## What this defends against

**Anyone without simultaneous database and deployment access.** That covers the realistic majority:
a compromised application credential, a malicious or careless user, a bug that writes the wrong row,
an ORM doing something clever, an attacker who reached the database but not the deployment pipeline.

Three layers, each independently sufficient against a different mistake:

1. **The database rejects mutation.** A trigger raises on `UPDATE`/`DELETE`, and the application role
   holds only `SELECT, INSERT`. An attacker with the connection string cannot edit the trail.
2. **The chain detects it anyway.** If the guard is removed and a row is edited, the per-tenant hash
   chain breaks and `Verify` names the first offending sequence.
3. **Retention cannot be used as cover.** Retiring a range records an anchor first, so "it aged out"
   is a checkable claim rather than an unfalsifiable one.

## What this does **not** defend against

**Your own operator.** Someone who can drop the trigger *and* has database access can recompute every
hash from the first entry forward and produce an internally consistent forged history. Nothing inside
the system detects that, because the system holds every input to the check.

This is not a weakness of this implementation — it is inherent to any self-hosted append-only log.
The only fix is publishing chain heads somewhere the operator does not control, which is
[Phase 2](../specs/002-anchoring-legal-hold/) and **not built**. Until then the honest claim is:

> The trail is tamper-evident against everyone except the party that runs it.

If your compliance requirement is "prove to a regulator that we could not have altered this", Phase 1
does not meet it. Say so rather than discovering it during an audit.

**Also out of scope:** reads are not audited (who looked at the trail is Phase 3), and a denial-of-
service that prevents recording is a producer-side concern — though note AR-005 means a failed
`security` write fails the producing action rather than silently proceeding unlogged.

## Producer trust

`Realm`, `Tenant` and `Actor` are **authoritative from the producer** and must never come from
request content. A producer that forwards a user-supplied actor id has built a log-forgery primitive:
the attacker chooses who appears to have done something.

In service mode producers authenticate (mTLS or a signed token). The trail is evidence, so an
unauthenticated producer path lets anyone write history.

## The no-body rule, and why it is enforced twice

Entries carry references and hashes — never prompts, responses, file contents, payloads or secrets.
Redaction runs in the recorder **and** the sink re-checks before appending.

Twice, because the recorder is a library the host compiles in, and this artifact is retained for
years and exported to a SIEM. One careless producer putting a prompt in `attributes` would make the
compliance record the largest secret leak in the system, discovered long after the fact
([D8](../specs/001-audit-core/design-decisions.md#d8)).

`result_hash` exists for exactly this: fingerprint what you will not store, so the body can be proven
against later without ever being retained.

## Isolation

Reads are scoped to `(realm, tenant)` by a `FORCE`d RLS policy. Forcing matters — without it the
table owner bypasses its own policy, and the owner is the role the application uses. No endpoint
accepts a tenant id as a parameter; identity comes from the session.

Verify isolation against *your* binding, as the role your application actually connects with. Running
the leak test as a superuser proves nothing.

## Roles are history, not permission

`actor_role` records what a role was at the time. Nothing reads it to decide anything
([D13](../specs/001-audit-core/design-decisions.md#d13)). Authorizing against a role stored on a
two-year-old entry either grants access that was revoked or denies access that was granted — and it
would put a write-mostly, SIEM-exported table on the live authorization path.

## Retention is a destructive control

Shortening a retention window destroys evidence. It is therefore privileged, audited as its own
`security` entry, and blocked by a legal hold. Treat a request to shorten retention the way you would
treat a request for database credentials.
