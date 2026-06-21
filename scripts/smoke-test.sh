#!/usr/bin/env bash
# smoke-test.sh — no-network checks for install seeding, org/spin plumbing, and
# provider routing. It runs in a temporary copy so the working tree stays clean.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

KIT="$TMP/spin"
mkdir -p "$KIT"
( cd "$ROOT" && git ls-files -z | tar --null -czf - --files-from - ) | tar -xzf - -C "$KIT"

cd "$KIT"
SPIN_NO_DEPS=1 \
SPIN_INSTALL_SKIP_AGENT_CHECK=1 \
SPIN_BIN_DIR="$TMP/bin" \
  ./install.sh >/dev/null

for f in scripts/*.sh scripts/lib/*.sh scripts/spin install.sh spin-bootstrap.sh; do
  bash -n "$f"
done
node --check scripts/org >/dev/null
node --check scripts/ceo-dashboard.js >/dev/null

scripts/org escalate "smoke approval needed" >/dev/null
status_out="$(SPIN_ROOT="$KIT" scripts/spin)"
grep -q "smoke approval needed" <<<"$status_out"

scripts/org queue-job example-app scout "inspect smoke path" --id smoke-scout >/dev/null
node -e '
  const q = JSON.parse(require("fs").readFileSync("org/AGENT_QUEUE.json", "utf8"));
  if (!q.jobs.some(j => j.id === "smoke-scout" && j.status === "queued")) process.exit(1);
'

FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/codex" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then echo "codex fake"; exit 0; fi
printf '%s\n' "\$*" > "$TMP/codex.args"
cat >/dev/null
EOF
chmod +x "$FAKEBIN/codex"

PATH="$FAKEBIN:$PATH" bash -c "
  set -euo pipefail
  source '$KIT/scripts/lib/ceo-waterfall.sh'
  run_agent codex 'hello' '$TMP/codex.log'
"
grep -q '^exec --cd ' "$TMP/codex.args"

bash -c "
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
