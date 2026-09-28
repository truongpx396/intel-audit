# Constitution

Principles this engine is held to. Each exists because violating it produced a real defect — in the
originating design, or in the class of audit systems this replaces.

## I. Immutability is enforced by the store, not promised by the API

An interface without an `Update` method constrains your code and nothing else. Not a `psql` session,
not a migration script, and not the attacker the trail exists to catch.

**In practice**: a trigger rejects mutation; the application role holds `SELECT, INSERT` only.

## II. A guarantee without an assertion is a comment

Every claim maps to something executable. The originating design specified a unique index that could
not be created, and an invariant pair that contradicted each other, and neither was noticed because
nothing ran them.

**In practice**: `make verify-schema` applies the migrations to a real PostgreSQL and asserts the
guarantees, including that the known-bad shape still fails for its documented reason.

## III. Housekeeping must never look like an attack

A mechanism that cannot distinguish its own maintenance from tampering trains operators to ignore its
alarm — and the one real alarm is ignored with the rest.

**In practice**: retirement records an anchor before the range goes away, so retired is provably
distinct from deleted.

## IV. The trail outlives the code that wrote it

Formats, canonicalization and vocabulary are permanent commitments. An entry written today must be
verifiable by a program written in another language, years from now.

**In practice**: `canonical()` is specified and pinned by golden vectors; changing it is a breaking
change to evidence.

## V. No bodies, ever

A record retained for years and exported to a SIEM is the worst possible place for a payload, a prompt
or a secret. References and hashes only, enforced twice.

## VI. State the threat model precisely, including who it excludes

Phase 1 is tamper-**evident**, not tamper-proof, and does not defend against the operator. Saying so
plainly is more useful than a claim that fails during an audit.

## VII. Opaque identity, permanently

The engine does not know what a tenant or an actor is. The moment it does, re-anchoring becomes a
migration and the engine stops being reusable.

## VIII. Silence is not success

An audit system that stops recording, stops anchoring, or stops verifying must say so loudly. Absence
of entries is indistinguishable from absence of activity, and that ambiguity is exploitable.

**In practice**: a failed `security` write fails its producing action; a stale chain head alarms.

## IX. Record the failure mode, not the preference

A decision is documented with what goes wrong without it. If no failure mode can be named, it is a
preference and belongs in a style guide.
