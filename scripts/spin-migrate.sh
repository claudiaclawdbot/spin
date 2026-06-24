#!/usr/bin/env bash
# spin-migrate.sh - run one-time SPIN runtime-state migrations.
#
# Migrations live in scripts/migrations/*.sh and are applied in lexical order.
# Each migration is recorded under org/.spin-migrations/ so reruns are safe.
set -euo pipefail

ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
MIGRATIONS_DIR="$ROOT/scripts/migrations"
STATE_DIR="$ROOT/org/.spin-migrations"
APPLIED="$STATE_DIR/applied"
DRY_RUN=0
LIST_ONLY=0

usage() {
  cat <<'EOF'
Usage: spin-migrate.sh [--dry-run] [--list]

Runs pending SPIN runtime-state migrations. This is normally called by
install.sh and spin update.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --list) LIST_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "spin-migrate: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

mkdir -p "$STATE_DIR"
touch "$APPLIED"

is_applied() {
  local id="$1"
  awk '{print $1}' "$APPLIED" | grep -Fxq "$id"
}

shopt -s nullglob
pending=()
for migration in "$MIGRATIONS_DIR"/*.sh; do
  id="$(basename "$migration")"
  if ! is_applied "$id"; then
    pending+=("$migration")
  fi
done
shopt -u nullglob

if [[ $LIST_ONLY -eq 1 ]]; then
  if [[ ${#pending[@]} -eq 0 ]]; then
    echo "spin-migrate: no pending migrations"
  else
    echo "spin-migrate: pending migrations:"
    for migration in "${pending[@]}"; do echo "  - $(basename "$migration")"; done
  fi
  exit 0
fi

if [[ ${#pending[@]} -eq 0 ]]; then
  echo "spin-migrate: no pending migrations"
  exit 0
fi

for migration in "${pending[@]}"; do
  id="$(basename "$migration")"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "spin-migrate: would run $id"
    continue
  fi
  echo "spin-migrate: running $id"
  SPIN_ROOT="$ROOT" bash "$migration"
  printf '%s %s\n' "$id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$APPLIED"
done
