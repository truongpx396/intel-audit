# Integration guide

How to adopt this in a host. You supply a realm, an identity binding, your actions and any extra
sinks; you touch nothing in the recording core.

> Implementation has not started, so the code is the intended API. The checklist and the reasoning
> are usable today.

## 1. Decide the identity binding

| Question | You pick | Example |
|---|---|---|
| Which product? | `Realm` | `"my-product"` — required, no default |
| What isolates trails? | `Tenant` | `{Kind: "workspace", ID: wsID}` |
| Who acts? | `Actor.Kind` | `user` · `agent` · `service` · `system` · `device` · `sandbox` |

**Set `Realm` even with one product.** It cannot be retrofitted cheaply — doing so means rewriting
every historical idempotency key, in the one table you are not allowed to rewrite.

## 2. Choose your action vocabulary

Dotted and stable: `member.invited`, `document.access_level_changed`, `tool.search_knowledge`,
`approval.resolved`. Actions are recorded forever, so treat renaming one as a breaking change to your
own history — old entries keep the old verb, and a query that assumes the new one silently misses
them.

## 3. Classify severity honestly

| Severity | Meaning | Consequence |
|---|---|---|
| `info` | telemetry; high volume | may buffer |
| `notice` | notable but not security-relevant | may buffer |
| `security` | access control, authn, permission, approval, admin action | **always synchronous** |
| `critical` | irreversible or externally consequential | **always synchronous** |

The synchronous rule is not tunable. If a `security` write fails, the producing action must fail —
proceeding unlogged is the failure this classification exists to prevent.

Over-classifying is the common mistake: mark everything `security` and you make every action wait on
a durable write, then someone "fixes the latency" by turning the guarantee off.

## 4. Record

```go
rec.Record(ctx, audit.Entry{
    Tenant:   audit.Tenant{Kind: "workspace", ID: wsID},
    Actor:    audit.Actor{Kind: "user", ID: userID, Role: role},
    Action:   "member.invited",
    Subject:  audit.Subject{Type: "invite", ID: inviteID},
    Severity: "security",
    IdemKey:  "invite:" + inviteID + ":created",   // REQUIRED, deterministic
})
```

`IdemKey` must derive deterministically from the originating resource and event. A random key makes
every retry a new entry, which is how an audit trail quietly becomes untrustworthy: it no longer
shows what happened, it shows how many times your bus retried.

## 5. Never put a body in `Attributes`

References and hashes only. If you need to prove what a body was, hash it into `ResultHash` and store
the body wherever bodies belong — with its own, shorter retention.

## Checklist

- [ ] **Realm set**, not shared with another product.
- [ ] **Tenant and Actor** constructed from trusted session context, never request content.
- [ ] **Action vocabulary** agreed and documented; renames treated as breaking.
- [ ] **Severity** assigned deliberately; `security` reserved for security-relevant events.
- [ ] **IdemKey** deterministic for every producer.
- [ ] **No bodies** in attributes — verified by a test with adversarial input.
- [ ] **Retention windows** set per severity; evidence outlives telemetry.
- [ ] **Legal hold** procedure documented before you need it.
- [ ] **Isolation verified** against your binding, as the role your app actually uses.
- [ ] **Verification exercised** in staging across a retirement boundary *before* enabling retention.
- [ ] **Alarms wired**, especially `audit.retention.anchor_missing`.

## Common mistakes

| Mistake | Consequence |
|---|---|
| Taking `Actor` from request content | Log forgery — the attacker picks who appears responsible |
| Random or non-deterministic `IdemKey` | Retries become distinct entries; the trail counts retries, not events |
| Marking everything `security` | Every action waits on a durable write, then someone disables the guarantee |
| Putting a body in `Attributes` | A years-retained, SIEM-exported secret leak |
| Enabling retention before verifying across a boundary | Verification reports tampering forever, unfixably |
| Reading `actor_role` for authorization | Stale permissions, and the audit table joins the auth path |
