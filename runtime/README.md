# SPIN Runtime

The runtime is the product logic that makes SPIN more than a terminal skin:
plain-file state, project registration, approvals, background jobs, receipts,
status boards, and model fallback.

Today the runtime still lives in:

- `scripts/` for commands and daemons.
- `org/` for runtime state templates and example project state.
- `docs/` for architecture and operator docs.

The macOS package script copies those files into:

```text
SPIN.app/Contents/Resources/runtime
```

Future migration should move stable modules here only when doing so reduces
coupling. Until then, keeping the existing CLI paths working is intentional:
`spin`, `org`, `spin up`, `spin init`, `spin approve`, and `spin doctor` remain
the power-user interface to the same app state.
