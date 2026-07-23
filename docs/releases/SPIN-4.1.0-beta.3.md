# SPIN for Mac 4.1.0 Beta 3

SPIN is a visual command center for coordinating AI coding agents across
multiple software projects. Each project keeps its own repository context,
while the Navigator handles portfolio priorities, delegation, approvals, and
progress from one Mac workspace.

## Highlights

- Runs the Navigator and isolated project agents in one visual workspace.
- Bundles the cmux-derived workspace engine and OMP/Pi agent runtime.
- Routes work across configured models and providers through OMP.
- Refines project handoffs with objectives, paths, constraints, and checks.
- Preserves queues, boards, handoffs, approvals, and receipts on disk.
- Serializes autonomous Navigator cycles to prevent overlapping portfolio runs.
- Restores app runtime and workspace state across relaunches.

## Requirements

- Apple silicon Mac
- macOS 14.0 or later
- At least one model/provider account supported by OMP
- Git and the normal development tools used by the managed projects

## Install

1. Download `SPIN-4.1.0-beta.3-macos-arm64.dmg`.
2. Open the DMG and drag `SPIN.app` into Applications.
3. Open SPIN and complete onboarding.

SPIN includes its workspace UI and agent runtime. Provider accounts, GitHub
authentication, source repositories, and project-specific tools remain under
the operator's control.

## macOS First Launch

This public beta is ad-hoc signed and not Apple-notarized. macOS may require a
Control-click on `SPIN.app` followed by **Open** on first launch. This is a
known distribution limitation, not an application health failure.

See the [Mac install guide](https://github.com/claudiaclawdbot/spin/blob/main/docs/INSTALL_MACOS.md)
for checksum verification and troubleshooting.

## Verify The Download

```bash
shasum -a 256 -c SPIN-4.1.0-beta.3-macos-arm64.dmg.sha256
```

DMG SHA-256:

```text
6b99c32db54365f3aa0025bf201a44cb91b409ef4c705c191e42f76c2ee2b7bf
```

## Open-Source Components

The release includes the exact modified cmux source tree used to build the
bundled GPL component, based on upstream commit
`fe87e608cbaef398c00027b0d0e0ba1a2721c165`. SPIN runtime source is MIT;
bundled and upstream components retain their own licenses and notices.
