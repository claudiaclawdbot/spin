# Security Policy

SPIN is a local orchestration harness for AI coding agents. It can run shell
commands through user-configured tools, so treat it like developer automation
with the same access as your macOS or Linux user account.

## Supported Versions

Security reports should target the current `main` branch and the latest public
SPIN.app beta release unless a report clearly affects an older release artifact.

## Reporting A Vulnerability

Please open a private security advisory on GitHub if available for this repo.
If that is not available, open a minimal public issue that says a security
report exists, without exploit details or secrets.

Include:

- SPIN version or release tag;
- macOS/Linux version and architecture;
- whether you used SPIN.app or the source/CLI install;
- whether the issue involves onboarding, provider setup, project floors,
  approvals, app updates, or bundled binaries;
- reproduction steps that do not expose private keys, tokens, or proprietary
  repository contents.

## Local Security Model

- SPIN is local-first. It does not provide an operating-system sandbox for
  agents.
- Agents and scripts can access files and commands available to the current
  user.
- Provider keys and accounts are owned by OMP/Pi or your normal CLI setup. Do
  not commit keys to this repo.
- External sends, spending, production deploys, and protected pushes have a
  second enforcement layer: `spin action` denies by default and only executes
  exact enabled rules from the local `org/ACTION_POLICY.json`. It records
  append-only events and a receipt for every execution attempt.
- Controller prompts also forbid direct execution, but SPIN still is not an OS
  security boundary. A same-user agent with arbitrary shell access can bypass a
  user-space broker. Keep high-value credentials in a separate OS account,
  container, or narrowly scoped wrapper that only the broker can invoke.
- Use dedicated low-value accounts, test wallets, and non-production keys while
  evaluating agent behavior.
- Review receipts and project state before trusting important results.

## Public Beta Notes

The current public macOS beta is ad-hoc signed and not notarized. Verify
release artifacts from GitHub, use the published checksum if desired, and only
remove quarantine for artifacts you intentionally downloaded from this project.

Production trust hardening is tracked in the app roadmap. Developer ID signing,
notarization, and remote update feeds are intentionally separate from the
current open-source beta path.
