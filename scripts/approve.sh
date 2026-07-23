#!/usr/bin/env bash
# approve.sh — append a decision to the Workspace CEO approvals channel.
#
#   ./scripts/approve.sh "APPROVE: built-by-ai Draft 1 send — go ahead and send Glam Tech"
#   ./scripts/approve.sh "DECLINE: fidget-play forge test — not yet"
#   ./scripts/approve.sh "ASK: which project is closest to revenue?"
#
# The line is inserted under the "## Pending" section of org/ceo/APPROVALS.md.
# The Workspace CEO reads it next tick (within ~15 min, sooner if you nudge it).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FILE="$ROOT/org/ceo/APPROVALS.md"
LOCK_FILE="$ROOT/org/ceo/runs/.org-approvals.lock"
MSG="${*:?usage: approve.sh \"APPROVE: <what> — <note>\"}"
source "$SCRIPT_DIR/lib/spin-runtime.sh"

LOCK_TOKEN=""
tmp=""
cleanup() {
  [ -z "$tmp" ] || rm -f "$tmp" 2>/dev/null || true
  if [ -n "$LOCK_TOKEN" ]; then
    spin_lock_release "$LOCK_FILE" "$LOCK_TOKEN" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

lock_attempt=0
while [ "$lock_attempt" -lt 50 ]; do
  lock_status=0
  spin_lock_acquire "$LOCK_FILE" || lock_status=$?
  if [ "$lock_status" -eq 0 ]; then
    LOCK_TOKEN="$SPIN_LOCK_OWNER_TOKEN"
    break
  fi
  if [ "$lock_status" -ne 1 ]; then
    echo "Could not acquire the approvals lock." >&2
    exit 3
  fi
  lock_attempt=$((lock_attempt + 1))
  sleep 0.1
done
if [ -z "$LOCK_TOKEN" ]; then
  echo "Approvals are busy; no decision was recorded." >&2
  exit 3
fi

TS="$(date -u '+%Y-%m-%dT%H:%MZ')"
LINE="- [$TS] $MSG"
tmp="$(mktemp "$FILE.tmp.XXXXXX")"
awk_status=0
awk -v line="$LINE" '
  {
    print
    header=$0
    sub(/^[[:space:]]*/, "", header)
    if (!done && tolower(header) ~ /^##[[:space:]]+pending[[:space:]]*$/) {
      print ""
      print line
      done=1
    }
  }
  END { if (!done) exit 42 }
' "$FILE" > "$tmp" || awk_status=$?
if [ "$awk_status" -eq 42 ]; then
  echo "APPROVALS.md has no Pending section; no decision was recorded." >&2
  exit 2
fi
if [ "$awk_status" -ne 0 ]; then
  echo "Could not update APPROVALS.md; no decision was recorded." >&2
  exit 3
fi
mv "$tmp" "$FILE"
tmp=""

echo "Recorded under Pending:"
echo "  $LINE"
echo "The Workspace CEO will act on it next tick."
