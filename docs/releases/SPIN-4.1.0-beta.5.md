# SPIN for Mac 4.1.0-beta.5

Beta 5 is the reliability and control-boundary release. It starts project work
from the selected repository, requires an explicit terminal outcome before
marking a job complete, and strengthens the owner gate around sensitive actions.

## Highlights

- Starts every queued provider in the registered project's canonical code root
  and loads that project's own provider overrides through an allowlisted,
  non-executable parser. The workspace-maintenance lane remains explicitly
  scoped to SPIN itself.
- Generates a separate OMP model-policy overlay for Coordinator, project floor,
  queued job, one-shot, and Navigator chat lanes so concurrent agents cannot
  replace one another's provider configuration.
- Binds singleton locks and detached jobs to process-start identities. Atomic
  hardlink acquisition closes empty-lock races, recycled PIDs cannot impersonate
  live work, and coordinated shutdown keeps replacement daemons out until the
  previous owner exits.
- Requires newly dispatched work to produce one semantic `COMPLETED` or
  `BLOCKED` receipt outcome. Missing or malformed outcome evidence fails closed
  and cannot unlock dependent jobs.
- Bounds each outer provider attempt from the job's runtime budget, preserves
  per-provider logs, and stops after ordinary task failures so partial work is
  not repeated by another provider. Task log text is never treated as retry
  permission.
- Separates live status observation from the time the underlying state last
  changed. The Control panel now keeps healthy idle systems live, treats an
  intentional pause as actionable, and hides acknowledged or resolved history
  from the attention count.
- Upgrades sensitive-action leases to bind the policy, executable bytes,
  resolved working directory, and exact target. Protected pushes additionally
  bind the resolved Git remote and destination branch, and reject remotes that
  fan out to more than one push URL.
- Runs broker commands with a fixed minimal environment plus only the variable
  names explicitly allowlisted by the owner. Git and XDG configuration
  selectors remain forbidden so execution cannot diverge from attestation.
- Makes all shipped JavaScript checks, focused Node tests, and error-level
  ShellCheck required CI gates.

## Action Policy Upgrade

The default deny-all policy needs no changes.

An existing enabled rule must add:

```json
{
  "executable_sha256": "<64 lowercase hex SHA-256>",
  "env_allowlist": []
}
```

Lease schema 1 records are intentionally rejected. Revoke the old lease, review
the updated rule, and arm a new short-lived lease. SPIN continues to deny the
action until all of those checks pass.

## Security Boundary

SPIN is a user-space control plane, not an operating-system sandbox. Agents run
as the current account. Keep high-value production credentials behind scoped
wrappers, separate accounts, containers, or provider-side restrictions when
bypass resistance is required.

## Release Gate

The public artifact is created only after the source branch passes required CI,
the checked macOS artifact workflow, installed-app first launch and restart
proof, checksum generation, and final deny-all verification.
