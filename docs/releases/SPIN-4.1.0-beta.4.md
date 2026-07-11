# SPIN for Mac 4.1.0-beta.4

Beta 4 hardens unattended execution and makes autonomous work easier to inspect
without weakening SPIN's local-first model.

## Highlights

- Adds a deny-by-default broker for external sends, spending, production
  deploys, and protected pushes. It matches exact owner-enabled rules, executes
  fixed command vectors, applies spend caps, and writes append-only receipts.
- Replaces broad direct-agent bypass flags with workspace-scoped or fail-closed
  fallback modes. OMP remains the primary model and provider router.
- Adds adaptive dispatch that preserves a system memory reserve. Normal jobs
  default to 3072 MB RSS and 16 processes; broad tests and native builds use one
  exclusive `heavy` lease capped at 6144 MB and 32 processes.
- Shows running, queued, blocked, failed, stale-heartbeat, dispatcher, RSS, and
  process state in the Coordinator board and local Control panel.
- Adds a Control entry to the SPIN dock and seeds the action policy during both
  fresh installs and upgrades.
- Includes a plain-language external beta protocol for testing restart truth,
  sensitive-action denial, heavy-job isolation, return use, and willingness to
  pay with real users.

## Security Boundary

The action broker is machine-enforced for work routed through it, but SPIN is
not an operating-system sandbox. Agents run as the current user. Put high-value
production credentials behind a separate OS account, container, or narrowly
scoped wrapper when bypass resistance is required.

## Requirements

- Apple silicon Mac
- macOS 13 or later
- At least one model/provider account supported by OMP
- Git and the normal development tools used by managed projects

## Install

1. Download `SPIN-4.1.0-beta.4-macos-arm64.dmg`.
2. Open the DMG and drag `SPIN.app` into Applications.
3. Control-click SPIN and choose **Open** if macOS blocks the first launch.
4. Complete OMP provider setup and add the first project.

The beta is ad-hoc signed and not Apple-notarized. Do not disable Gatekeeper
system-wide.

## Verify The Download

```bash
shasum -a 256 -c SPIN-4.1.0-beta.4-macos-arm64.dmg.sha256
```

DMG SHA-256:

```text
c5db5612220eb37dc740d7f5d1a79126d73ecbb14d0fbb1905233ab120cdc7f8
```

The checked release workflow also verified app identity, bundled binary
resolution, runtime seeding, restart/session restore, state preservation,
compatibility metadata, code signatures, DMG extraction, and installed-app
first launch.

## Open-Source Components

The release includes the exact modified cmux source tree used to build the
bundled GPL component, based on upstream commit
`fe87e608cbaef398c00027b0d0e0ba1a2721c165`. SPIN runtime source is MIT;
bundled and upstream components retain their own licenses and notices.
