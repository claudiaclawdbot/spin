#!/usr/bin/env bash
# smoke-test.sh — no-network checks for install seeding, org/spin plumbing, and
# provider routing. It runs in a temporary copy so the working tree stays clean.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

KIT="$TMP/spin"
mkdir -p "$KIT"
( cd "$ROOT" && { git ls-files -z; git ls-files -z --others --exclude-standard -- 'org/ceo/*.example.md'; } | tar --null -czf - --files-from - ) | tar -xzf - -C "$KIT"

cd "$KIT"
SPIN_NO_DEPS=1 \
SPIN_INSTALL_SKIP_AGENT_CHECK=1 \
SPIN_BIN_DIR="$TMP/bin" \
  ./install.sh >/dev/null

test -f org/ceo/CEO_CHAT_PROMPT.md
test -f org/projects/workspace/PROJECT_CONTROLLER_PROMPT.md
test -f org/projects/workspace/STATE.json

for f in scripts/*.sh scripts/lib/*.sh scripts/spin install.sh spin-bootstrap.sh; do
  bash -n "$f"
done
node --check scripts/org >/dev/null
node --check scripts/ceo-dashboard.js >/dev/null

scripts/org escalate "smoke approval needed" >/dev/null
status_out="$(SPIN_ROOT="$KIT" scripts/spin)"
grep -q "smoke approval needed" <<<"$status_out"

scripts/org queue-job example-app scout "inspect smoke path; quoted ' value" --id smoke-scout >/dev/null
if scripts/org queue-job example-app scout "bad id path" --id '../bad' >/dev/null 2>&1; then
  echo "bad job id accepted"
  exit 1
fi
node -e '
  const q = JSON.parse(require("fs").readFileSync("org/AGENT_QUEUE.json", "utf8"));
  if (!q.jobs.some(j => j.id === "smoke-scout" && j.status === "queued")) process.exit(1);
'

cat > scripts/project-ceo-agent.sh <<EOF
#!/usr/bin/env bash
{
  printf 'id=%s\n' "\${OMP_JOB_ID:-}"
  printf 'type=%s\n' "\${OMP_JOB_TYPE:-}"
  printf 'description=%s\n' "\${OMP_JOB_DESCRIPTION:-}"
  printf 'project=%s\n' "\${1:-}"
} > "$TMP/project-agent.env"
EOF
chmod +x scripts/project-ceo-agent.sh
scripts/omp-supervisor-once.sh >/dev/null
for _ in 1 2 3 4 5; do
  [[ -f "$TMP/project-agent.env" ]] && break
  sleep 0.2
done
scripts/omp-supervisor-once.sh >/dev/null
grep -q "description=inspect smoke path; quoted ' value" "$TMP/project-agent.env"
node -e '
  const q = JSON.parse(require("fs").readFileSync("org/AGENT_QUEUE.json", "utf8"));
  const j = q.jobs.find(j => j.id === "smoke-scout");
  if (!j || j.status !== "completed") process.exit(1);
'

FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
SMOKE_HOME="$TMP/home"
mkdir -p "$SMOKE_HOME"
cat > "$FAKEBIN/cmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/cmux.calls"
case "\${1:-}" in
  ping) exit 0 ;;
  tree) echo "surface:7 [terminal]"; exit 0 ;;
  read-screen) echo "model: sonnet-4-6"; exit 0 ;;
  send|send-key) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$FAKEBIN/cmux"

PATH="$FAKEBIN:$PATH" SPIN_ROOT="$KIT" \
  scripts/delegate.sh --id smoke-delegate example-app "make ascii art" > "$TMP/delegate.out"
grep -q 'delegated smoke-delegate to example-app' "$TMP/delegate.out"
grep -q 'delegate smoke-delegate complete:' "$TMP/cmux.calls"
grep -q 'ceo -> example-app: delegate smoke-delegate: make ascii art' org/ceo/runs/delegations.log

cat > "$FAKEBIN/codex" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then echo "codex fake"; exit 0; fi
printf '%s\n' "\$*" > "$TMP/codex.args"
cat >/dev/null
EOF
chmod +x "$FAKEBIN/codex"

PATH="$FAKEBIN:$PATH" HOME="$SMOKE_HOME" bash -c "
  set -euo pipefail
  source '$KIT/scripts/lib/ceo-waterfall.sh'
  run_agent codex 'hello' '$TMP/codex.log'
"
grep -q '^exec --cd ' "$TMP/codex.args"

cat > "$FAKEBIN/omp" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--help" ]]; then echo "omp fake"; exit 0; fi
printf '%s\n' "\$*" > "$TMP/omp.args"
exit 0
EOF
chmod +x "$FAKEBIN/omp"

PATH="$FAKEBIN:$PATH" HOME="$SMOKE_HOME" SPIN_OMP_CONFIG="$TMP/spin-omp.yml" CEO_OMP_MODEL=openrouter/test-model bash -c "
  set -euo pipefail
  source '$KIT/scripts/lib/ceo-waterfall.sh'
  run_agent omp 'hello' '$TMP/omp.log'
"
grep -q -- '--config' "$TMP/omp.args"
grep -q -- "$TMP/spin-omp.yml" "$TMP/omp.args"
if grep -q -- '--model' "$TMP/omp.args"; then
  echo "omp run pinned --model instead of using fallback config"
  exit 1
fi
grep -q 'fallbackChains:' "$TMP/spin-omp.yml"
grep -q 'openai-codex/gpt-5-codex' "$TMP/spin-omp.yml"
grep -q 'openrouter/test-model' "$TMP/spin-omp.yml"

HOME="$SMOKE_HOME" bash -c "
  set -euo pipefail
  source '$KIT/scripts/lib/ceo-waterfall.sh'
  probe_claude(){ return 1; }
  probe_gemini(){ return 1; }
  probe_omp(){ return 0; }
  probe_ollama(){ return 0; }
  run_agent(){ echo \"\$1\" > '$TMP/provider'; return 0; }
  run_agent_resilient true '' prompt '$TMP/provider.log'
"
grep -q '^omp$' "$TMP/provider"

echo "smoke ok"
