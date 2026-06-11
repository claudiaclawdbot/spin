#!/usr/bin/env bash
# launch-project-omx-ceo.sh — DEPRECATED shim.
#
# Superseded by project-ceo-agent.sh (single run) + project-ceo-loop.sh (loop),
# which share scripts/lib/ceo-waterfall.sh. Kept so any historical AGENT_QUEUE
# commands and muscle-memory invocations still work: it forwards to the new
# agent, preserving OMP_JOB_* env passthrough and PROJECT_CEO_PROVIDER/MODEL.
#
# Usage: launch-project-omx-ceo.sh <project-id>

set -euo pipefail
ROOT="${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_ID="${1:?usage: launch-project-omx-ceo.sh <project-id>}"

echo "[deprecated] launch-project-omx-ceo.sh → project-ceo-agent.sh $PROJECT_ID" >&2
exec "$ROOT/scripts/project-ceo-agent.sh" "$PROJECT_ID"
