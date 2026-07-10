#!/usr/bin/env bash
# Fetch/build upstream sources/packages used as SPIN app foundations.
#
# This is intentionally separate from install.sh. Developer installs should stay
# light; release engineering can opt into vendoring/fork setup explicitly.
set -euo pipefail

ROOT="${SPIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CMUX_REPO="${SPIN_CMUX_REPO:-https://github.com/manaflow-ai/cmux.git}"
OMP_REPO="${SPIN_OMP_REPO:-https://github.com/can1357/oh-my-pi.git}"
OMP_PACKAGE="${SPIN_OMP_PACKAGE:-@oh-my-pi/pi-coding-agent}"
OMP_VERSION="${SPIN_OMP_VERSION:-}"
if [ -z "$OMP_VERSION" ] && command -v node >/dev/null 2>&1 && [ -f "$ROOT/agent/vendor/omp/package.json" ]; then
  OMP_VERSION="$(node -e 'const p=require(process.argv[1]); process.stdout.write(p.dependencies[process.argv[2]] || "")' \
    "$ROOT/agent/vendor/omp/package.json" "$OMP_PACKAGE" 2>/dev/null || true)"
fi
OMP_VERSION="${OMP_VERSION:-16.4.0}"
OMP_PACKAGE_SPEC="${SPIN_OMP_PACKAGE_SPEC:-$OMP_PACKAGE@$OMP_VERSION}"
BUN_MIN_VERSION="${SPIN_BUN_MIN_VERSION:-1.3.14}"
BUN_BIN="${SPIN_BUN_BIN:-$(command -v bun || true)}"
DO_CMUX=1
DO_OMP=1

usage() {
  cat <<'EOF'
Usage: scripts/vendor-app-deps.sh [--cmux-only|--omp-only]

Fetches app foundation sources and builds the repeatable OMP/Pi release input.

Environment:
  SPIN_OMP_VERSION        OMP package version to vendor (default: current pinned manifest)
  SPIN_OMP_UPDATE_LOCK    set to 1 to refresh agent/vendor/omp/bun.lock
  SPIN_VENDOR_FULL_CLONE  set to 1 to clone full upstream git history
EOF
}

for arg in "$@"; do
  case "$arg" in
    --cmux-only) DO_OMP=0 ;;
    --omp-only) DO_CMUX=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

mkdir -p "$ROOT/app/upstream" "$ROOT/agent/upstream" "$ROOT/agent/vendor/npm" "$ROOT/agent/vendor/omp" "$ROOT/vendor/bin"

fail(){ echo "vendor app deps failed: $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
require_cmd(){ have "$1" || fail "$1 not found"; }

version_ge() {
  node - "$1" "$2" <<'NODE'
const [got, want] = process.argv.slice(2);
const parts = (v) => String(v).split(/[.-]/).map((x) => Number.parseInt(x, 10) || 0);
const a = parts(got);
const b = parts(want);
for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
  if ((a[i] || 0) > (b[i] || 0)) process.exit(0);
  if ((a[i] || 0) < (b[i] || 0)) process.exit(1);
}
NODE
}

platform_tag() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os:$arch" in
    Darwin:arm64) printf 'darwin-arm64\n' ;;
    Darwin:x86_64) printf 'darwin-x64\n' ;;
    Linux:x86_64) printf 'linux-x64\n' ;;
    Linux:aarch64|Linux:arm64) printf 'linux-arm64\n' ;;
    *) fail "unsupported OMP vendor platform: $os/$arch" ;;
  esac
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

clone_or_update() {
  local repo="$1" dir="$2"
  if [ -d "$dir/.git" ]; then
    echo "updating $dir"
    if [ "${SPIN_VENDOR_FULL_CLONE:-}" = "1" ]; then
      git -C "$dir" fetch --tags --prune
    else
      git -C "$dir" fetch --depth 1 --filter=blob:none --prune origin
    fi
    return
  fi
  echo "cloning $repo -> $dir"
  if [ "${SPIN_VENDOR_FULL_CLONE:-}" = "1" ]; then
    git clone "$repo" "$dir"
  else
    git clone --depth 1 --filter=blob:none "$repo" "$dir"
  fi
}

pin_omp_source() {
  local dir="$1" tag="v$OMP_VERSION"
  git -C "$dir" fetch --depth 1 origin "refs/tags/$tag:refs/tags/$tag"
  git -C "$dir" checkout --detach "$tag" >/dev/null
}

write_omp_vendor_manifest() {
  node - "$ROOT/agent/vendor/omp/package.json" "$OMP_PACKAGE" "$OMP_VERSION" <<'NODE'
const fs = require('fs');
const [out, pkg, version] = process.argv.slice(2);
const manifest = {
  private: true,
  name: "@spin/omp-vendor",
  description: "Pinned OMP/Pi release input for the SPIN app bundle.",
  dependencies: {
    [pkg]: version,
  },
};
fs.writeFileSync(out, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
}

build_omp_vendor() {
  require_cmd npm
  require_cmd node
  [ -n "$BUN_BIN" ] && [ -x "$BUN_BIN" ] || fail "bun not found; install Bun >= $BUN_MIN_VERSION or set SPIN_BUN_BIN"
  local bun_version
  bun_version="$("$BUN_BIN" --version 2>/dev/null | head -1)"
  version_ge "$bun_version" "$BUN_MIN_VERSION" || fail "bun $bun_version is older than required $BUN_MIN_VERSION"

  local tag native_name vendor_dir npm_dir build_dir dist_json tarball_url tarball_shasum tarball_integrity pack_file
  tag="$(platform_tag)"
  native_name="pi_natives.$tag.node"
  vendor_dir="$ROOT/agent/vendor/omp"
  npm_dir="$ROOT/agent/vendor/npm"
  build_dir="$(mktemp -d)"

  write_omp_vendor_manifest

  echo "packing $OMP_PACKAGE_SPEC"
  dist_json="$(npm view "$OMP_PACKAGE_SPEC" dist --json)"
  tarball_url="$(printf '%s\n' "$dist_json" | node -e 'const fs=require("fs"); const d=JSON.parse(fs.readFileSync(0,"utf8")); console.log(d.tarball || "");')"
  tarball_shasum="$(printf '%s\n' "$dist_json" | node -e 'const fs=require("fs"); const d=JSON.parse(fs.readFileSync(0,"utf8")); console.log(d.shasum || "");')"
  tarball_integrity="$(printf '%s\n' "$dist_json" | node -e 'const fs=require("fs"); const d=JSON.parse(fs.readFileSync(0,"utf8")); console.log(d.integrity || "");')"
  pack_file="$(cd "$npm_dir" && npm pack "$OMP_PACKAGE_SPEC" --silent)"

  cp "$vendor_dir/package.json" "$build_dir/package.json"
  local install_args=(install --no-progress)
  if [ -f "$vendor_dir/bun.lock" ] && [ "${SPIN_OMP_UPDATE_LOCK:-}" != "1" ]; then
    cp "$vendor_dir/bun.lock" "$build_dir/bun.lock"
    install_args+=(--frozen-lockfile)
  else
    install_args+=(--save-text-lockfile)
  fi

  echo "installing pinned OMP/Pi package graph with bun $bun_version"
  (cd "$build_dir" && "$BUN_BIN" "${install_args[@]}")
  [ -f "$build_dir/bun.lock" ] || fail "bun did not write bun.lock; rerun with Bun >= $BUN_MIN_VERSION or set SPIN_BUN_BIN"
  if [ ! -f "$vendor_dir/bun.lock" ] || [ "${SPIN_OMP_UPDATE_LOCK:-}" = "1" ]; then
    cp "$build_dir/bun.lock" "$vendor_dir/bun.lock"
  fi

  local entry native_src out_bin out_native version_out check_home
  entry="$(node - "$build_dir" "$OMP_PACKAGE" <<'NODE'
const path = require('path');
const fs = require('fs');
const [root, pkg] = process.argv.slice(2);
const pkgJson = path.join(root, 'node_modules', ...pkg.split('/'), 'package.json');
const manifest = JSON.parse(fs.readFileSync(pkgJson, 'utf8'));
const bin = typeof manifest.bin === 'string' ? manifest.bin : manifest.bin && manifest.bin.omp;
process.stdout.write(path.join(path.dirname(pkgJson), bin || 'dist/cli.js'));
NODE
)"
  native_src="$build_dir/node_modules/@oh-my-pi/pi-natives-$tag/$native_name"
  [ -f "$entry" ] || fail "OMP entrypoint not found after install: $entry"
  [ -f "$native_src" ] || fail "OMP native addon not found after install: $native_src"

  out_bin="$ROOT/vendor/bin/omp"
  out_native="$ROOT/vendor/bin/$native_name"
  echo "compiling OMP/Pi $OMP_VERSION -> $out_bin"
  "$BUN_BIN" build --compile "$entry" --outfile "$out_bin"
  cp "$native_src" "$out_native"
  chmod +x "$out_bin"

  check_home="$(mktemp -d)"
  version_out="$(env -i HOME="$check_home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$out_bin" --version)"
  rm -rf "$check_home"
  case "$version_out" in
    "omp/$OMP_VERSION") ;;
    *) fail "vendored omp reported unexpected version: $version_out" ;;
  esac

  local source_commit=""
  if [ -d "$ROOT/agent/upstream/oh-my-pi/.git" ]; then
    source_commit="$(git -C "$ROOT/agent/upstream/oh-my-pi" rev-parse HEAD 2>/dev/null || true)"
  fi

  node - "$ROOT" "$vendor_dir/metadata.json" "$OMP_PACKAGE" "$OMP_VERSION" "$OMP_PACKAGE_SPEC" \
    "$OMP_REPO" "$source_commit" "$tag" "$native_name" "$tarball_url" "$tarball_shasum" "$tarball_integrity" \
    "$npm_dir/$pack_file" "$vendor_dir/bun.lock" "$BUN_MIN_VERSION" "$bun_version" "$out_bin" "$out_native" <<'NODE'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const [
  root, out, pkg, version, spec, repo, sourceCommit, platformTag, nativeName,
  tarballUrl, tarballShasum, tarballIntegrity, packFile, lockFile, bunMinimumVersion, bunVersion, binFile, nativeFile,
] = process.argv.slice(2);
const rel = (file) => path.relative(root, file);
const sha256 = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const meta = {
  package: pkg,
  version,
  packageSpec: spec,
  upstream: repo,
  upstreamSource: "agent/upstream/oh-my-pi",
  upstreamCommit: sourceCommit || null,
  npm: {
    tarball: tarballUrl,
    shasum: tarballShasum,
    integrity: tarballIntegrity,
    localPack: rel(packFile),
    localPackSha256: sha256(packFile),
  },
  build: {
    runtime: "bun build --compile",
    bunMinimumVersion,
    bunVersion,
    lockfile: {
      path: rel(lockFile),
      sha256: sha256(lockFile),
    },
    platformTag,
    nativeAddon: nativeName,
  },
  outputs: [
    { kind: "compiled-cli", path: rel(binFile), sha256: sha256(binFile) },
    { kind: "native-addon", path: rel(nativeFile), sha256: sha256(nativeFile) },
  ],
};
fs.writeFileSync(out, `${JSON.stringify(meta, null, 2)}\n`);
NODE

  echo "vendored OMP/Pi:"
  echo "  package: $OMP_PACKAGE_SPEC"
  echo "  binary: $out_bin"
  echo "  native addon: $out_native"
  echo "  metadata: $vendor_dir/metadata.json"
  rm -rf "$build_dir"
}

if [ "$DO_CMUX" = "1" ]; then
  clone_or_update "$CMUX_REPO" "$ROOT/app/upstream/cmux"
fi

if [ "$DO_OMP" = "1" ]; then
  clone_or_update "$OMP_REPO" "$ROOT/agent/upstream/oh-my-pi"
  pin_omp_source "$ROOT/agent/upstream/oh-my-pi"
  build_omp_vendor
fi

cmux_line="  cmux source: $ROOT/app/upstream/cmux"
omp_source_line="  OMP/Pi source: $ROOT/agent/upstream/oh-my-pi"
omp_pack_line="  OMP npm pack: $ROOT/agent/vendor/npm"
omp_bin_line="  OMP binary: $ROOT/vendor/bin/omp"

cat <<EOF

Fetched app foundations:
${cmux_line}
${omp_source_line}
${omp_pack_line}
${omp_bin_line}

Next release steps:
  1. Build the cmux fork as SPIN.app plus a cmux-compatible CLI.
  2. Run scripts/build-app-proof.sh --source-cmux.
  3. Confirm scripts/check-app-release.sh dist/SPIN.app passes with SPIN_REQUIRE_VENDORED_OMP=1.
EOF
