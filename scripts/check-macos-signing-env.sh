#!/usr/bin/env bash
# Report whether the local macOS signing/notarization environment is ready.
set -euo pipefail

PRODUCTION="${SPIN_RELEASE_PRODUCTION:-0}"
if [ "${1:-}" = "--production" ]; then
  PRODUCTION=1
elif [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
Usage: scripts/check-macos-signing-env.sh [--production]

Reports Developer ID signing and notarization readiness without printing
credentials or secrets.

Environment:
  SPIN_CODESIGN_IDENTITY       Developer ID Application identity for production
  SPIN_CODESIGN_HARDENED       1 for hardened runtime; default depends on identity
  SPIN_APPLE_TEAM_ID           optional Apple team id
  SPIN_CMUX_ENTITLEMENTS       production entitlements for bundled cmux app
  SPIN_OMP_ENTITLEMENTS        optional OMP entitlements; generated if omitted
  SPIN_OUTER_ENTITLEMENTS      optional outer app entitlements
  SPIN_NOTARIZE                1 for production notarization
  SPIN_NOTARY_PROFILE          notarytool keychain profile name
  SPIN_VALIDATE_NOTARY_PROFILE 1 to make a live notarytool profile probe
EOF
  exit 0
fi

failures=0
warns=0

ok(){ echo "  ok: $*"; }
warn(){ echo "  warn: $*"; warns=$((warns+1)); }
fail(){ echo "  fail: $*"; failures=$((failures+1)); }

require_production() {
  if [ "$PRODUCTION" = "1" ]; then fail "$1"; else warn "$1"; fi
}

echo "SPIN macOS signing environment"

if [ "$(uname -s)" != "Darwin" ]; then
  require_production "macOS is required for signing and notarization"
else
  ok "macOS host"
fi

for tool in codesign security xcrun spctl ditto; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool available"
  else
    require_production "$tool not found"
  fi
done

IDENTITY="${SPIN_CODESIGN_IDENTITY:--}"
HARDENED="${SPIN_CODESIGN_HARDENED:-}"
if [ -z "$HARDENED" ]; then
  if [ "$IDENTITY" = "-" ]; then HARDENED=0; else HARDENED=1; fi
fi
TEAM_ID="${SPIN_APPLE_TEAM_ID:-}"

identity_out=""
if command -v security >/dev/null 2>&1; then
  identity_out="$(security find-identity -v -p codesigning 2>/dev/null || true)"
fi
developer_identities="$(printf '%s\n' "$identity_out" | grep 'Developer ID Application' || true)"
developer_count="$(printf '%s\n' "$developer_identities" | sed '/^$/d' | wc -l | tr -d ' ')"
if [ "$developer_count" -gt 0 ]; then
  ok "Developer ID Application identities available: $developer_count"
else
  require_production "no Developer ID Application signing identities found"
fi

if [ "$IDENTITY" = "-" ]; then
  require_production "SPIN_CODESIGN_IDENTITY is ad-hoc '-'"
else
  if printf '%s\n' "$identity_out" | grep -F "$IDENTITY" >/dev/null 2>&1; then
    ok "configured signing identity found: $IDENTITY"
  else
    require_production "configured signing identity not found in keychain: $IDENTITY"
  fi
  if [ -z "$TEAM_ID" ]; then
    TEAM_ID="$(printf '%s\n' "$identity_out" | grep -F "$IDENTITY" | sed -n 's/.*(\([A-Z0-9][A-Z0-9]*\)).*/\1/p' | head -1)"
  fi
fi

if [ -n "$TEAM_ID" ]; then
  ok "Apple team id configured: $TEAM_ID"
else
  require_production "SPIN_APPLE_TEAM_ID not configured and no team id could be inferred"
fi

case "$HARDENED" in
  0)
    require_production "SPIN_CODESIGN_HARDENED is disabled"
    ;;
  1)
    ok "hardened runtime enabled"
    ;;
  *)
    require_production "SPIN_CODESIGN_HARDENED must be 0 or 1, got: $HARDENED"
    ;;
esac

if [ -n "${SPIN_CMUX_ENTITLEMENTS:-}" ]; then
  [ -f "$SPIN_CMUX_ENTITLEMENTS" ] && ok "cmux entitlements: $SPIN_CMUX_ENTITLEMENTS" \
    || require_production "SPIN_CMUX_ENTITLEMENTS not found: $SPIN_CMUX_ENTITLEMENTS"
else
  require_production "SPIN_CMUX_ENTITLEMENTS not configured for production cmux signing"
fi

if [ "$HARDENED" = "1" ]; then
  if [ -n "${SPIN_OMP_ENTITLEMENTS:-}" ]; then
    [ -f "$SPIN_OMP_ENTITLEMENTS" ] && ok "OMP entitlements: $SPIN_OMP_ENTITLEMENTS" \
      || require_production "SPIN_OMP_ENTITLEMENTS not found: $SPIN_OMP_ENTITLEMENTS"
  else
    ok "OMP entitlements will be generated with disable-library-validation"
  fi
else
  warn "OMP hardened-runtime entitlement not needed while hardened runtime is disabled"
fi

if [ -n "${SPIN_OUTER_ENTITLEMENTS:-}" ]; then
  [ -f "$SPIN_OUTER_ENTITLEMENTS" ] && ok "outer app entitlements: $SPIN_OUTER_ENTITLEMENTS" \
    || require_production "SPIN_OUTER_ENTITLEMENTS not found: $SPIN_OUTER_ENTITLEMENTS"
else
  warn "SPIN_OUTER_ENTITLEMENTS not configured; outer app will be signed without custom entitlements"
fi

if [ "${SPIN_NOTARIZE:-0}" = "1" ]; then
  ok "notarization requested"
else
  require_production "SPIN_NOTARIZE is not enabled"
fi

if [ -n "${SPIN_NOTARY_PROFILE:-}" ]; then
  ok "notarytool profile configured: $SPIN_NOTARY_PROFILE"
  if [ "${SPIN_VALIDATE_NOTARY_PROFILE:-0}" = "1" ]; then
    if xcrun notarytool history --keychain-profile "$SPIN_NOTARY_PROFILE" >/dev/null 2>&1; then
      ok "notarytool profile validated"
    else
      require_production "notarytool profile validation failed: $SPIN_NOTARY_PROFILE"
    fi
  else
    warn "notarytool profile not live-validated; set SPIN_VALIDATE_NOTARY_PROFILE=1 to probe Apple"
  fi
else
  require_production "SPIN_NOTARY_PROFILE not configured"
fi

if [ "$PRODUCTION" = "1" ] && [ "$failures" -gt 0 ]; then
  echo "SPIN signing environment is not production-ready ($failures failure(s), $warns warning(s))."
  exit 1
fi

if [ "$failures" -gt 0 ]; then
  echo "SPIN signing environment has $failures production blocker(s) and $warns warning(s)."
else
  echo "SPIN signing environment preflight complete ($warns warning(s))."
fi
