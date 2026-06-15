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
ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
FILE="$ROOT/org/ceo/APPROVALS.md"
MSG="${*:?usage: approve.sh \"APPROVE: <what> — <note>\"}"
TS="$(date -u '+%Y-%m-%dT%H:%MZ')"
LINE="- [$TS] $MSG"

# Insert after the "## Pending" header line.
tmp="$(mktemp)"
awk -v line="$LINE" '
  { print }
  /^## Pending/ && !done { print ""; print line; done=1 }
' "$FILE" > "$tmp" && mv "$tmp" "$FILE"

echo "Recorded under Pending:"
echo "  $LINE"
echo "The Workspace CEO will act on it next tick."
