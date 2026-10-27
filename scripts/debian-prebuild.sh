#!/bin/bash
# =============================================================================
# qadam-flow — Debian prebuild (payload staging)
# =============================================================================
# Produces the runtime payload dpkg-buildpackage packages, WITHOUT bun:
#
#   1. refresh package-lock.json so it carries the npm `overrides` from
#      package.json (npm ci fails on an overrides/unlocked mismatch),
#   2. npm ci (full install — the .deb ships this exact node_modules, so the
#      bundled-qadam metadata later reflects the shipped tree; a prod-only
#      prune is a later optimization, see the header of debian/README.md),
#   3. npx turbo build: web, engine, api, worker, all bundled qadams,
#   4. the three manifests Docker writes: packages/qadams/dist-index.json
#      (#419), packages/server/api/dist/src/migration-manifest.json, and
#      packages/qadams/bundled-qadams-metadata.json (#598),
#   5. stage everything into debian/prebuild/usr in the exact layout
#      debian/qadam-flow-common.install picks up.
#
# Before step 1 the workspace dependency specs are rewritten bun-style
# "workspace:*" -> npm "file:" by scripts/workspace-to-file.cjs and restored
# when this script exits (successfully or on error), so the repo is untouched
# by the time dpkg-buildpackage runs.
#
# Run order on the buildbot:
#   scripts/debian-prebuild.sh && dpkg-buildpackage -us -uc -b
# debian/rules override_dh_auto_build fails loudly when the stage is missing.
# =============================================================================
# =============================================================================

set -euo pipefail
cd "$(dirname "$0")/.."

STAGE=debian/prebuild/usr
TREE="$STAGE/lib/qadam-flow"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log()  { echo -e "${CYAN}[PREBUILD]${NC} $1"; }
fail() { echo -e "${RED}[FATAL]${NC} $1" >&2; exit 1; }

command -v node >/dev/null || fail "node is not installed"
command -v npm  >/dev/null || fail "npm is not installed"
test -f package.json   || fail "package.json missing"
test -d packages/qadams || fail "packages/qadams missing"

echo "version  : $(node -p 'require("./package.json").version')"
echo "node/npm : $(node --version) / $(npm --version)"

# --- 0. workspace specs -> npm file: (restored automatically on exit) ---------
# The mono-repo is bun-native ("workspace:*"); npm rejects that protocol. The
# EXIT trap is installed BEFORE apply so a crashed apply still restores the
# files it already rewrote (the transform itself also stashes per file).
trap '{ node scripts/workspace-to-file.cjs restore || true; }' EXIT
node scripts/workspace-to-file.cjs apply

# --- 1. lock refresh so npm ci sees the root `overrides` ----------------------
# A COMMITTED package-lock.json is the source of truth on the npm path (bun
# users ignore it): the buildbot never silently adopts a fresh registry state.
# Regenerate deliberately with REFRESH_LOCK=1 after dependency changes.
if [ -f package-lock.json ] && [ "${REFRESH_LOCK:-0}" != "1" ]; then
    log "using committed package-lock.json (REFRESH_LOCK=1 to regenerate)"
else
    log "refreshing package-lock.json (npm install --package-lock-only)"
    npm install --package-lock-only --ignore-scripts --no-fund --no-audit
    ok "package-lock.json refreshed"
fi

# --- 2. full dependency install ----------------------------------------------
# REDISMS_DISABLE_POSTINSTALL=1 matches the Docker build: the redis client's
# postinstall musl/glibc probe must not run on Debian (redis comes from the
# system package).
log "npm ci (full workspace install)"
REDISMS_DISABLE_POSTINSTALL=1 npm ci --no-fund --no-audit
ok "node_modules ready"

# --- 3. build ----------------------------------------------------------------
log "npx turbo build (web, engine, api, worker, all bundled qadams)"
npx turbo run build --filter=web --filter=@aiqadam/engine --filter=api \
    --filter=worker --filter='@aiqadam/qadam-*'
test -f packages/server/api/dist/src/bootstrap.js  || fail "api build output missing"
test -f packages/server/worker/dist/src/bootstrap.js || fail "worker build output missing"
test -d dist/packages/web                          || fail "web build output missing"
test -d dist/packages/engine                       || fail "engine build output missing"
ok "builds verified"

# --- 4. manifests (exact Dockerfile commands) --------------------------------
log "writing packages/qadams/dist-index.json (#419)"
npx tsx packages/server/engine/src/scripts/write-qadam-dist-index.ts packages/qadams
test -s packages/qadams/dist-index.json || fail "dist-index.json was not written"

log "writing packages/server/api/dist/src/migration-manifest.json"
node -e "\
  const {getMigrations} = require('./packages/server/api/dist/src/app/database/postgres-connection');\
  const names = getMigrations().map(M => new M().name);\
  process.stdout.write(JSON.stringify(names));\
" > packages/server/api/dist/src/migration-manifest.json
test -s packages/server/api/dist/src/migration-manifest.json || fail "migration-manifest.json was not written"

log "writing packages/qadams/bundled-qadams-metadata.json (#598)"
node packages/server/api/dist/src/scripts/write-bundled-qadams-manifest.js packages/qadams
test -s packages/qadams/bundled-qadams-metadata.json || fail "bundled-qadams-metadata.json was not written"
ok "manifests ready"

# --- 5. stage ----------------------------------------------------------------
log "restoring workspace specs (the payload ships the original package.json)"
node scripts/workspace-to-file.cjs restore

log "staging payload into $STAGE"
rm -rf debian/prebuild
mkdir -p "$TREE" "$STAGE/share/qadam-flow" "$STAGE/local/etc"

cp -a node_modules "$TREE/node_modules"
cp -a packages "$TREE/packages"
# dist ships WITHOUT the web build — Debian FHS puts the frontend under
# /usr/share/qadam-flow/web and dh_link symlinks dist/packages/web to it.
cp -a dist "$TREE/dist"
rm -rf "$TREE/dist/packages/web"
cp -a dist/packages/web "$STAGE/share/qadam-flow/web"

for f in package.json bun.lock bunfig.toml .npmrc LICENSE NOTICE; do
    test -f "$f" || fail "root file missing: $f"
    install -m 0644 "$f" "$TREE/$f"
done

cp -a packages/server/api/src/assets/default.cf "$STAGE/local/etc/isolate"

ok "staged $(du -sh debian/prebuild | cut -f1) under debian/prebuild"
echo "Next: RUN_CHECKS=yes dpkg-buildpackage -us -uc -b  (or via the buildbot builder)"
