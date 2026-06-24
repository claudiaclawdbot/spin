# SPIN Migrations

Place one-time runtime-state migrations in this directory as executable
`*.sh` files. `scripts/spin-migrate.sh` runs them in lexical order and records
applied migrations under `org/.spin-migrations/`.

Migration scripts run with `SPIN_ROOT` set to the repository root. They should
be idempotent anyway, because users may restore backups or run migrations by
hand while debugging.
