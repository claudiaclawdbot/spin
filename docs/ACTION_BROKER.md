# Sensitive Action Broker

SPIN lets agents do local, reversible work without asking. Four actions take a
different path: external sends, spending, production deploys, and protected
pushes.

`spin action` starts in deny-all mode. It never accepts arbitrary command text
from an agent. The owner must add an exact, enabled rule to the local
`org/ACTION_POLICY.json`. That file is runtime state and is not committed.
Keep it non-writable by group or other users (`chmod 600`).

An enabled rule is still not executable by itself. The broker also requires a
short-lived, one-shot lease in the private sibling file
`org/ACTION_POLICY.lease.json`. The lease never changes the policy schema. It
binds one rule id to the SHA-256 digest of the exact policy bytes and an expiry.
The broker consumes the lease under its lock before starting the fixed command.
Consequently, a crash before or after process spawn cannot leave a reusable
authorization behind.

## Rule Format

```json
{
  "version": 1,
  "mode": "deny-by-default",
  "rules": [
    {
      "id": "push-spin-main",
      "category": "protected-push",
      "target": "github.com/claudiaclawdbot/spin:main",
      "enabled": true,
      "command": ["/usr/bin/git", "push", "origin", "HEAD:main"],
      "cwd": "/absolute/path/to/spin",
      "timeout_seconds": 300
    }
  ]
}
```

Commands are fixed argv arrays and run without a shell. Use absolute executable
paths. `${SPIN_ROOT}` and `${HOME}` are the only supported placeholders. Do not
put secrets in the policy, command arguments, reasons, or targets.

A spend rule also needs positive caps:

```json
{
  "id": "buy-approved-test-credit",
  "category": "spend",
  "target": "vendor.example:test-credit",
  "enabled": false,
  "command": ["/absolute/path/to/scoped-purchase-wrapper"],
  "cwd": "${SPIN_ROOT}",
  "timeout_seconds": 120,
  "per_action_usd": "10.00",
  "per_day_usd": "25.00"
}
```

Every started spend counts against the daily cap. This is conservative on
purpose: if the broker is interrupted after a vendor accepted a payment, it
does not assume the money was unspent.

## One-shot leases

Only the local owner should arm a lease. Arming requires an explicit marker and
the broker writes `ACTION_POLICY.lease.json` with mode `0600`, fsyncs it, and
atomically renames it into place. The lease is intentionally a single-rule
capability, not a second allowlist.

```bash
SPIN_OWNER_CONFIRMED=1 spin action lease arm push-spin-main \
  --ttl-seconds 900 \
  --owner-marked \
  --json
```

`--ttl-seconds` is a required integer from `1` through `3600`. The broker will
not begin a command with less than one second remaining. `--owner-marked` and
`SPIN_OWNER_CONFIRMED=1` are both required; they make the owner acknowledgement
explicit in the lease record and arming path. The fixed rule timeout governs a
command that has already started, because the lease is consumed before spawn.
The marker is not a substitute for OS-account isolation.

After a successful or failed execution attempt, the lease is already consumed.
Arm another one only after reviewing the outcome. To cancel an unused lease:

```bash
spin action lease revoke --json
```

Missing, expired, malformed, group/world-readable, wrong-owner, wrong-digest,
or wrong-rule leases all deny `check` and `execute`. Expiry is harmless across a
reboot because the broker compares the persisted UTC timestamp on every use.

For an expired lease that still exactly binds the current policy and an enabled
rule, the owner or control plane may safely deactivate that stale rule:

```bash
spin action lease recover --json
```

Recovery is deliberately explicit. A `status` probe does not rewrite policy.
It reports `recovery_available: true` only when that bounded deactivation is
safe. A missing or mismatched lease is never used as authority to edit policy.

## Machine-readable status contract

`spin action status --json` is the Company CLI probe. Existing fields remain
available. Lease-aware consumers must use the following stable fields instead
of treating `enabled_rules > 0` as authorization:

```json
{
  "status": "ready|lease_required|deny_all|missing",
  "enabled_rules": 1,
  "executable_rules": 0,
  "lease_support": {
    "version": 1,
    "policy_rule_expiry": true,
    "rejects_expired_execution": true,
    "recovers_expired_policy": true
  },
  "lease": {
    "schema_version": 1,
    "supports_expiring_one_shot_leases": true,
    "required_for_enabled_rules": true,
    "owner_mark_required": true,
    "owner_confirmation_required": true,
    "consume_before_spawn": true,
    "active": false,
    "execution_allowed": false,
    "recovery_available": false,
    "state": "missing|active|expired|policy_mismatch|rule_mismatch|untrusted",
    "rule_id": null,
    "expires_at": null,
    "policy_sha256": null,
    "max_ttl_seconds": 3600
  }
}
```

An automation may execute only when all of these are true: `status == "ready"`,
`executable_rules > 0`, `lease.active`, and `lease.execution_allowed`. It must
then expect the lease to disappear before the child command begins. Use
`spin action lease status --json` for the lease-only subset.

## Agent Flow

```bash
spin action check protected-push \
  --target "github.com/claudiaclawdbot/spin:main" \
  --rule push-spin-main

spin action execute protected-push \
  --target "github.com/claudiaclawdbot/spin:main" \
  --rule push-spin-main \
  --reason "Ship the owner-approved release"
```

When no exact rule is enabled:

```bash
spin action request production-deploy \
  --target "app.example.com" \
  --reason "Release candidate passed its required checks"
```

The request is added once to `org/HUMAN_QUEUE.md`; no command runs. Execution
events go to `org/action-broker/events.jsonl`, and each attempt gets a JSON
receipt under `org/action-broker/receipts/`.

## Boundary

The broker enforces actions routed through it. SPIN agents still run as the
current OS user, so a fully arbitrary same-user shell can call another binary
directly. For hard isolation, keep production credentials in another OS account
or container and expose only a narrowly scoped broker command.
