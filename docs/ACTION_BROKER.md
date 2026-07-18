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
Lease schema 2 also binds the executable's resolved path and SHA-256 digest,
plus the resolved working directory. The broker consumes the lease under its
lock before starting the fixed command.
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
      "executable_sha256": "<64 lowercase hex SHA-256 of the resolved executable>",
      "env_allowlist": [],
      "cwd": "/absolute/path/to/spin",
      "timeout_seconds": 300
    }
  ]
}
```

Commands are fixed argv arrays and run without a shell. Use absolute executable
paths. `${SPIN_ROOT}` and `${HOME}` are the only supported placeholders. Do not
put secrets in the policy, command arguments, reasons, or targets.

Every enabled rule must set `executable_sha256` to the digest of the resolved
executable. For example, `shasum -a 256 /usr/bin/git` prints the digest to put
in a rule that executes `/usr/bin/git`. Arming records that digest, the resolved
executable path, and the resolved `cwd` in the one-shot lease. `check` and
`execute` deny the rule if the executable bytes change or either configured path
resolves somewhere else.

Every enabled rule must also include `env_allowlist`. Use `[]` when the command
needs no variables from the broker process. The child receives only fixed
`HOME`, `PATH`, `LANG`, and `LC_ALL` values plus names explicitly listed by the
rule. Code-injection and configuration-override variables cannot be allowlisted.
That includes every `GIT_*`, `DYLD_*`, and `LD_*` name, plus the XDG
configuration selectors. The receipt records allowlisted names, never their
values.

For `protected-push`, the fixed command must be a direct
`git push <remote> <source>:<branch>`. When a lease is armed, SPIN resolves the
remote's push URL from the pinned working directory under the same constrained
environment used for execution. The named remote must resolve to exactly one
push URL; Git configurations that fan one push out to multiple URLs are denied.
SPIN requires the resolved repository plus destination branch to equal the
rule's exact target. The lease and receipt record the canonical repository,
destination, and a hash of the remote URL. If the remote is retargeted later,
execution fails closed without exposing any credentials that may be embedded in
the URL.

A spend rule also needs positive caps:

```json
{
  "id": "buy-approved-test-credit",
  "category": "spend",
  "target": "vendor.example:test-credit",
  "enabled": false,
  "command": ["/absolute/path/to/scoped-purchase-wrapper"],
  "executable_sha256": "<64 lowercase hex SHA-256 of the resolved executable>",
  "env_allowlist": [],
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
wrong-rule, or wrong-attestation leases all deny `check` and `execute`. Expiry
is harmless across a reboot because the broker compares the persisted UTC
timestamp on every use.

Lease schema 1 files and enabled rules created before executable pinning fail
closed after this upgrade. Add `executable_sha256` and `env_allowlist` to each
enabled rule, revoke the old lease if present, review the updated policy, and
arm a new schema 2 lease. The seeded deny-all policy needs no migration.

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
    "version": 2,
    "policy_rule_expiry": true,
    "rejects_expired_execution": true,
    "recovers_expired_policy": true,
    "owner_marked_arm": true,
    "one_shot_consume_before_spawn": true,
    "executable_sha256_binding": true,
    "resolved_path_binding": true,
    "protected_push_target_binding": true,
    "explicit_environment_allowlist": true
  },
  "lease": {
    "schema_version": 2,
    "supports_expiring_one_shot_leases": true,
    "required_for_enabled_rules": true,
    "owner_mark_required": true,
    "owner_confirmation_required": true,
    "consume_before_spawn": true,
    "active": false,
    "execution_allowed": false,
    "recovery_available": false,
    "state": "missing|active|expired|policy_mismatch|rule_mismatch|attestation_mismatch|untrusted",
    "rule_id": null,
    "expires_at": null,
    "policy_sha256": null,
    "executable_realpath": null,
    "executable_sha256": null,
    "cwd_realpath": null,
    "target_attestation": null,
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
