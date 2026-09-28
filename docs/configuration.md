# Configuration

`audit.Config` is the entire configuration surface. The core reads no global config and no
environment variables; adapters dial what they are given.

| Field | Default | Notes |
|---|---|---|
| `Realm` | **none — required** | Rejected if empty: a plausible default silently merges two products' key spaces ([D1](../specs/001-audit-core/design-decisions.md#d1)) |
| `StoreDSN` | **none — required** | PostgreSQL |
| `RedisURL` | `""` | **Optional.** Advisory cache for the chain head only; absence costs one query ([D4](../specs/001-audit-core/design-decisions.md#d4)) |
| `Durability` | `sync` | `sync` or `buffered`. **Ignored for `security`/`critical`**, which are always synchronous |
| `Retention` | per severity | `info` 30d · `notice` 90d · `security` 7y · `critical` 7y |
| `AnchorOnRetire` | `true` | Retiring without an anchor makes verification report tampering forever. Settable to `false` only so the failure is a deliberate choice, never an accident |
| `MaxAttempts` | `5` | Secondary-sink deliveries before terminal |
| `BackoffBase` / `BackoffCeiling` | `10s` / `1h` | Full jitter |

## Environment mapping (service mode)

```bash
AUDIT_REALM=my-product          # required
AUDIT_PG_DSN=postgres://...     # required
AUDIT_REDIS_URL=                # optional; advisory cache only
AUDIT_DURABILITY=sync
AUDIT_RETENTION_INFO=720h
AUDIT_RETENTION_SECURITY=61320h
AUDIT_ANCHOR_ON_RETIRE=true
```

## Validation

`Config.Validate()` applies defaults to a copy and returns every problem at once, so a misconfigured
deployment fails at startup with a complete list. It rejects an empty `Realm` or `StoreDSN`, a
non-positive retention window, a `security` window shorter than an `info` one (almost always a
transposition), and `BackoffCeiling < BackoffBase`.

The severity-ordering check is unusual for a config validator and deliberate: getting it backwards
silently discards the evidence while keeping the noise, and nothing downstream would complain.
