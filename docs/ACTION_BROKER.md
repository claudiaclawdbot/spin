# Sensitive Action Broker

SPIN lets agents do local, reversible work without asking. Four actions take a
different path: external sends, spending, production deploys, and protected
pushes.

`spin action` starts in deny-all mode. It never accepts arbitrary command text
from an agent. The owner must add an exact, enabled rule to the local
`org/ACTION_POLICY.json`. That file is runtime state and is not committed.
Keep it non-writable by group or other users (`chmod 600`).

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
