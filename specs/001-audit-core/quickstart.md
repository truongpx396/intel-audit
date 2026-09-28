# Quickstart

> **Implementation not started.** The Go below describes the intended interface. What runs today is
> `make verify-schema`, which is real and worth running.

## What works today

```bash
make verify-schema   # apply migrations to a throwaway PG16, assert the seven guarantees
make lint-sql        # migration hygiene
```

`verify-schema` also reproduces the inherited constraint failure before applying the fix, and asserts
the *specific* Postgres error rather than merely a nonzero exit — so the finding is demonstrated, not
asserted.

## Intended: as a library

```go
rec, err := app.New(audit.Config{
    Realm:    "my-product",              // required, no default
    StoreDSN: os.Getenv("AUDIT_PG_DSN"),
    Retention: map[audit.Severity]time.Duration{
        "info":     30 * 24 * time.Hour,
        "security": 7 * 365 * 24 * time.Hour,
    },
}, app.Deps{
    Sinks: sinks,                        // postgres registered by default
    Chain: pg.NewChain(db),
})

// A human action.
rec.Record(ctx, audit.Entry{
    Tenant:   audit.Tenant{Kind: "workspace", ID: wsID},
    Actor:    audit.Actor{Kind: "user", ID: userID, Role: "admin"},
    Action:   "member.invited",
    Subject:  audit.Subject{Type: "invite", ID: inviteID},
    Severity: "security",                // => written synchronously, whatever the mode
    IdemKey:  "invite:" + inviteID + ":created",
})

// An AI tool call. Same call, different actor kind -- not a different table.
rec.Record(ctx, audit.Entry{
    Tenant:   audit.Tenant{Kind: "workspace", ID: wsID},
    Actor:    audit.Actor{Kind: "agent", ID: userID, Role: "researcher"},
    Action:   "tool.search_workspace_knowledge",
    Subject:  audit.Subject{Type: "document", ID: docID},
    Severity: "info",
    Attributes: map[string]string{"token_cost": "1420", "trace_id": traceID},
    IdemKey:  "run:" + runID + ":step:" + stepID,
})
```

## Verifying a tenant's chain

```go
rep, err := verifier.Verify(ctx, tenant, from, to)
// rep.Intact, rep.FromSeq, rep.ToSeq, rep.AnchorsTraversed, rep.BreakSeq, rep.Detail
```

`rep` reports the range it covered, not just a boolean — "intact" over an unstated range answers
nothing in a dispute ([D9](design-decisions.md#d9)). A range crossing retired
data resolves through anchors and still reports intact.

## Adding a sink

```go
type SplunkSink struct{ c *splunk.Client }

func (SplunkSink) Kind() string { return "splunk" }

func (s SplunkSink) Append(ctx context.Context, e audit.Sealed) (audit.Receipt, error) {
    // Idempotent on (e.Realm, e.Tenant, e.IdemKey) -- the drainer re-drives after a crash.
    return s.c.Send(ctx, e)
}
```

Then `sinks.Register(splunk.New(c))`. Fan-out commits an outbox row with the entry, so a Splunk
outage delays the backhaul instead of losing it.

## Next

- [docs/integration-guide.md](../../docs/integration-guide.md) — adopting it properly.
- [docs/operations.md](../../docs/operations.md) — retention, anchors, on-demand verification.
- [docs/security.md](../../docs/security.md) — the threat model, including what this does **not** stop.
