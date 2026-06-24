# Upgrading SPIN

SPIN has a first-class updater:

```bash
spin update
```

The update command is intentionally conservative. It fast-forwards the current
checkout only when that can be done without overwriting local tracked edits, and
it protects user runtime state before changing code.

## What `spin update` Does

1. Verifies this is a Git checkout.
2. Fetches the current branch upstream and tags.
3. Prints the current version, current checkout, newest local tag, and target.
4. Refuses to continue if tracked SPIN files have local edits.
5. Refuses to continue while project jobs are running.
6. Backs up `org/` and `logs/` to `.spin/backups/spin-state-<timestamp>.tgz`.
7. Pauses the SPIN driver if it is running.
8. Fast-forwards to the update target.
9. Runs `install.sh`, which refreshes links, records `org/.spin-version`, and
   applies pending runtime migrations.
10. Runs `spin doctor`.
11. Restarts the driver if it was running before the update.

## Common Commands

```bash
spin update --check
spin update --dry-run
spin update --no-restart
spin update --allow-running-jobs
spin version
```

Use `--allow-running-jobs` only when you understand that existing project jobs
may continue running code from the previous checkout while SPIN's scripts update.

## Rollback

The updater uses fast-forward Git updates and writes a local state backup before
the code changes.

To roll code back to the previous commit:

```bash
git reflog --date=iso
git reset --hard <previous-spin-commit>
./install.sh
```

To restore runtime state from the backup:

```bash
tar xzf .spin/backups/spin-state-YYYYMMDD-HHMMSS.tgz
```

Rollback is intentionally manual because it can replace live `org/` state. Stop
the driver first with `spin stop` if the org is running.

## Maintainer Notes

- Keep `VERSION` updated for user-visible releases.
- Add runtime migrations as executable `scripts/migrations/*.sh` files.
- Migrations run in lexical order through `scripts/spin-migrate.sh`.
- Applied migrations are recorded in `org/.spin-migrations/applied`.
- Migrations should be idempotent anyway; users may restore an old backup and run
  them again while recovering.
- Avoid breaking existing `org/OMP_HARNESS.json`, project prompts, or `STATE.json`
  without adding a migration and documenting the release impact.
