# SPIN App

This directory is the product shell for the self-contained SPIN app.

SPIN is the visible product. The cmux fork is treated as the internal native UI
engine: terminal surfaces, browser panes, workspaces, sidebars, notifications,
and socket control. Users should not need to install `cmux` separately once a
release bundle exists.

Current milestone:

- Define the app bundle contract in `spin-app.json`.
- Provide SPIN-branded cmux defaults in `cmux/config/` and `cmux/sidebars/`.
- Package the current runtime into `SPIN.app` with `scripts/package-macos-app.sh`.
- Resolve bundled `Resources/bin/cmux` before falling back to a developer PATH.
- Build a bounded local proof app with `scripts/build-app-proof.sh`, which
  bundles the cmux app at `Contents/Resources/SPIN.app`. Use
  `scripts/build-app-proof.sh --source-cmux` for the full Xcode source-build
  fork proof; source mode packages the Xcode-built `SPIN` CLI internally as
  `Resources/bin/cmux`.

See `docs/APP_ROADMAP.md` for app-track checkpoints and keep core runtime work
in `docs/ROADMAP.md`.

The actual long-lived cmux fork should live under `app/upstream/cmux` or a
separate `spin-cmux` repository, then be copied into releases as `SPIN.app` and
`Resources/bin/cmux`.
