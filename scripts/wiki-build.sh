#!/usr/bin/env bash
# wiki-build.sh — auto-generates the "Key files" index for a project wiki.
#
# Karpathy pattern: agents read org/wiki/projects/<id>.md, not raw source files.
# This script is the librarian — it keeps the file index fresh from the actual
# filesystem. The context sections (What it is / Current state / Hard rules) are
# written and maintained by the agent; this script never touches them.
#
# Usage:
#   bash scripts/wiki-build.sh <project-id>
#   bash scripts/wiki-build.sh built-by-ai
#
# Run after cloning a new project, or call from wiki-watch.sh on file changes.

set -uo pipefail
ROOT="${WORKSPACE_ROOT:-${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}}"

# ── args ─────────────────────────────────────────────────────────────────────
PROJECT="${1:-}"
if [[ -z "$PROJECT" ]]; then
  echo "Usage: $0 <project-id>" >&2
  exit 1
fi

PROJECT_DIR="$ROOT/projects/$PROJECT"
WIKI_DIR="$ROOT/org/wiki/projects"
WIKI_FILE="$WIKI_DIR/$PROJECT.md"
TEMPLATE="$(cd "$(dirname "$0")/.." && pwd)/templates/wiki/projects/PROJECT_TEMPLATE.md"

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "[wiki-build] ERROR: project dir not found: $PROJECT_DIR" >&2
  exit 1
fi

mkdir -p "$WIKI_DIR"
TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ── build file index ─────────────────────────────────────────────────────────
# Collect files worth indexing: skip build artifacts, lock files, binaries, hidden dirs.
SKIP_DIRS=".git|node_modules|.next|dist|build|out|.turbo|coverage|__pycache__|.cache|vendor|target|venv|.venv"
SKIP_FILES="package-lock.json|yarn.lock|pnpm-lock.yaml|Gemfile.lock|Cargo.lock|poetry.lock|*.min.js|*.min.css|*.map|*.ico|*.png|*.jpg|*.svg|*.woff|*.woff2|*.ttf"

file_purpose() {
  local f="$1"
  local name; name="$(basename "$f")"
  local ext="${name##*.}"
  local rel="${f#$PROJECT_DIR/}"

  # Well-known files get a fixed description
  case "$name" in
    package.json)        echo "npm manifest — deps, scripts, entry points" ;;
    tsconfig.json)       echo "TypeScript compiler config" ;;
    next.config.*)       echo "Next.js build config" ;;
    tailwind.config.*)   echo "Tailwind CSS config" ;;
    .env.example)        echo "env var template (copy to .env, never commit .env)" ;;
    Dockerfile)          echo "container image definition" ;;
    docker-compose.yml)  echo "local service stack definition" ;;
    Makefile)            echo "make targets — build/test/deploy shortcuts" ;;
    README.md)           echo "project overview and setup guide" ;;
    AGENTS.md|CLAUDE.md) echo "agent instructions and project rules" ;;
    FLOOR.md)            echo "live agent status board (goal/now/next/blockers)" ;;
    *)
      # Infer from path
      case "$rel" in
        src/app/api/*)          echo "API route handler" ;;
        src/app/*)              echo "Next.js page or layout" ;;
        src/components/*)       echo "UI component" ;;
        src/lib/*|src/utils/*)  echo "shared utility / helper" ;;
        src/hooks/*)            echo "React hook" ;;
        src/types/*)            echo "TypeScript types / interfaces" ;;
        scripts/*)              echo "dev or automation script" ;;
        lib/*)                  echo "library / shared module" ;;
        test/*|__tests__/*)     echo "test suite" ;;
        prisma/schema.*)        echo "database schema (Prisma)" ;;
        supabase/migrations/*)  echo "DB migration" ;;
        contracts/*)            echo "smart contract" ;;
        *)
          # Fall back to reading first meaningful comment line
          local first
          first="$(grep -m1 -E '^\s*(//|#|/\*|\*)\s*.{10,}' "$f" 2>/dev/null | sed 's/^\s*[/#*]\+\s*//' | cut -c1-80)"
          echo "${first:-$ext file}"
          ;;
      esac
      ;;
  esac
}

build_index() {
  echo "| File | Purpose |"
  echo "|------|---------|"

  # Priority files first
  local priority=(
    "README.md" "AGENTS.md" "CLAUDE.md" "package.json"
    "src/app/layout.tsx" "src/app/page.tsx"
    "prisma/schema.prisma" "supabase/schema.sql"
  )
  local seen=()

  for name in "${priority[@]}"; do
    local path="$PROJECT_DIR/$name"
    [[ -f "$path" ]] || continue
    local rel="${path#$PROJECT_DIR/}"
    echo "| \`$rel\` | $(file_purpose "$path") |"
    seen+=("$path")
  done

  # Then everything else, sorted, skipping hidden dirs and artifacts
  while IFS= read -r f; do
    # Skip already-shown priority files
    local skip=0
    for s in "${seen[@]+"${seen[@]}"}"; do [[ "$f" == "$s" ]] && skip=1 && break; done
    [[ $skip -eq 1 ]] && continue

    local rel="${f#$PROJECT_DIR/}"
    echo "| \`$rel\` | $(file_purpose "$f") |"
  done < <(
    find "$PROJECT_DIR" -type f \
      | grep -vE "/($SKIP_DIRS)/" \
      | grep -vE "($(echo "$SKIP_FILES" | tr '|' '\n' | sed 's/\./\\./g; s/\*/.*/g' | tr '\n' '|' | sed 's/|$//'))$" \
      | grep -vE '/\.[^/]+$' \
      | sort \
      | head -60
  )
}

# ── repo layout ───────────────────────────────────────────────────────────────
build_tree() {
  # Top-level dirs + notable files, max 3 levels
  if command -v tree &>/dev/null; then
    tree "$PROJECT_DIR" -L 3 -I "$(echo "$SKIP_DIRS" | tr '|' '|')" --noreport 2>/dev/null | head -40
  else
    find "$PROJECT_DIR" -maxdepth 2 -not -path "*/.git/*" \
      | grep -vE "/($SKIP_DIRS)($|/)" \
      | sed "s|$PROJECT_DIR/||" | sort | head -40
  fi
}

# ── merge with existing wiki ──────────────────────────────────────────────────
# If a wiki file exists, preserve sections the agent has written.
# We only regenerate: "Repo layout" and "Key files".
# Everything else (What it is / Current state / Hard rules / What agent can do) is kept.

if [[ -f "$WIKI_FILE" ]]; then
  # Extract preserved sections (everything except Repo layout and Key files blocks)
  PRESERVED="$(awk '
    /^## Repo layout/ { skip=1 }
    /^## Key files/   { skip=1 }
    /^## / && skip    { skip=0 }
    !skip             { print }
  ' "$WIKI_FILE" | sed '/^_Auto-generated file index/d' | sed '/^_Last index rebuild/d')"
else
  # Bootstrap from template if it exists, otherwise use a minimal stub
  if [[ -f "$TEMPLATE" ]]; then
    PRESERVED="$(sed "s|<project-id>|$PROJECT|g" "$TEMPLATE" | \
      awk '/^## (Key files|Repo layout)/{skip=1} /^## / && !/^## (Key files|Repo layout)/{skip=0} !skip{print}')"
  else
    PRESERVED="# $PROJECT — Project Wiki

_Agent-maintained context doc. Read this first. Update when state changes significantly._

## What it is

[fill in]

## Current state

[fill in]

## Hard rules

- Never push to \`main\` directly
- Never commit \`.env\` or secrets
- Never deploy without human approval
"
  fi
fi

# ── write the wiki ────────────────────────────────────────────────────────────
{
  # Emit preserved header + context sections
  echo "$PRESERVED" | sed '/^## Repo layout/,$d'

  echo ""
  echo "## Repo layout"
  echo ""
  echo "\`\`\`"
  build_tree
  echo "\`\`\`"
  echo ""

  echo "## Key files"
  echo ""
  echo "_Auto-generated file index — updated by \`scripts/wiki-build.sh\`. Do not edit this section by hand._"
  echo "_Last index rebuild: ${TS}_"
  echo ""
  build_index
  echo ""

  # Emit any remaining preserved sections after Key files (e.g. custom agent notes)
  echo "$PRESERVED" | awk '/^## Key files/,0 { if (/^## / && !/^## Key files/) print }' || true
} > "$WIKI_FILE"

echo "[wiki-build] $PROJECT → $WIKI_FILE (${TS})"
