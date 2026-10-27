#!/bin/bash
# =============================================================================
# qadam-flow — Debian prebuild (copy-out: the repo tree is never written)
# =============================================================================
# Runs the npm/npx toolchain inside a disposable copy of the repo and stages
# the runtime payload dpkg-buildpackage packages, WITHOUT bun:
#
#     build/
#       package-lock.json   REFRESH_LOCK=1 product — commit it (see step 3)
#       source/             full disposable copy of the repo root (no .git,
#                           build, node_modules, dist, .turbo, .env*)
#       deb/                final artifacts (filled by the dpkg-buildpackage
#                           step; see debian/README.md for the full chain)
#
# Every step writes OVER build/source and never the repo working tree. Even
# the repo's package.json manifests are not transformed in place here (see
# scripts/workspace-to-file.cjs — the derivation happens inside the copy):
#
#   1. copy the repo root into build/source (tar pipe; cache/artifact-free),
#   2. derive npm-compatible manifests inside the copy: `overrides` mirrored
#      from `resolutions`, direct deps the overrides redirect dropped (npm
#      EOVERRIDE — the rollup case), workspace:* specs -> file: in members,
#   3. package-lock.json, three-state:
#        REFRESH_LOCK=1             -> regenerate from the registry inside the
#                                      copy; product build/package-lock.json,
#                                      commit it to the repo root (the only
#                                      bootstrap step that is a git operation
#                                      and it is yours, not this script's),
#        committed package-lock.json -> use it verbatim (reproducible build),
#        neither                    -> fail: npm ci on the derived tree would
#                                      silently re-resolve the registry,
#   4. npm ci (full install — the .deb ships this exact node_modules, so the
#      bundled-qadam metadata later reflects the shipped tree; a prod-only
#      prune is a later optimization, see the header of debian/README.md),
#   5. npx turbo build: web, engine, api, worker, all bundled qadams,
#   6. the three manifests Docker writes: packages/qadams/dist-index.json
#      (#419), packages/server/api/dist/src/migration-manifest.json, and
#      packages/qadams/bundled-qadams-metadata.json (#598),
#   7. restore the REPO manifests over the copy — the staged payload then
#      carries the original workspace:* spelling and nothing parses dep specs
#      outside installs,
#   8. stage into build/source/debian/prebuild/usr in the exact layout
#      debian/qadam-flow-common.install picks up.
#
# Local run order (bootstrap; first ever run, then once per dependency bump):
#     REFRESH_LOCK=1 bash scripts/debian-prebuild.sh
#     cp build/package-lock.json package-lock.json && git add package-lock.json
#     ( cd build/source && dpkg-buildpackage -us -uc -b )
#     mkdir -p build/deb && mv build/qadam-flow_* build/deb/
#
# Run order on the buildbot:
#     bash ./scripts/debian-prebuild.sh   (committed lock present — reproducible)
#     dpkg-buildpackage -us -uc -b        (inside build/source, see the yaml)
# debian/rules override_dh_auto_build fails loudly when the stage is missing.
# A rerun wipes build/ (fresh copy, fresh node_modules) — fully idempotent.
# =============================================================================
# =============================================================================

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
SRC="$BUILD/source"
LOCK_OUT="$BUILD/package-lock.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log()  { echo -e "${CYAN}[PREBUILD]${NC} $1"; }
fail() { echo -e "${RED}[FATAL]${NC} $1" >&2; exit 1; }

command -v node >/dev/null || fail "node is not installed"
command -v npm  >/dev/null || fail "npm is not installed"
command -v tar  >/dev/null || fail "tar is not installed"
command -v git  >/dev/null || fail "git is not installed (the copy-out is the index's file list)"
test -f "$ROOT/package.json"     || fail "package.json missing in $ROOT"
test -d "$ROOT/packages/qadams"  || fail "packages/qadams missing"
test "$SRC" != "$ROOT"           || fail "internal error: the source copy is the repo root"
cd "$ROOT"

# The vendored .npmrc interpolates ${NPM_TOKEN}; the bot has no token (it
# exists to publish). Modern npm no longer throws on an undefined interpolant
# (the placeholder is shipped literally), but a missing token becomes a
# registry-side rejection on the first registry-touching command — setting a
# stable sentinel keeps public packuments flowing; if the registry ever
# started gating on it, the bot would export a real token instead.
export NPM_TOKEN="${NPM_TOKEN:-debian-build-placeholder}"

echo "version  : $(node -p 'require("./package.json").version')"
echo "node/npm : $(node --version) / $(npm --version)"

# --- 0. build inputs are committed ----------------------------------------------
# The payload ships the repo's package.json manifests verbatim (step 7) and
# the staged .npmrc/bunfig/debian/ files ride along with them; anything
# locally-modified in those paths would silently diverge from what the
# buildbot would build from the same commit. NUL-delimited status (no
# porcelain quoting for odd paths), filtered to the build inputs. Local only
# (the bot's checkout is a clobbered clone).
if test -d "$ROOT/.git"; then
    DIRTY=$(git -C "$ROOT" status --porcelain=v1 -z -- package.json packages .npmrc bunfig.toml bun.lock debian \
        | tr '\0' '\n' \
        | grep -E 'package\.json$|\.npmrc$|bunfig\.toml$|bun\.lock$|[[:space:]]debian/' || true)
    if [ -n "$DIRTY" ]; then
        echo "$DIRTY" >&2
        fail "build inputs are modified/untracked in the repo — commit them first"
    fi
fi

# --- 1. copy-out ---------------------------------------------------------------
# Tracked files only, via the index — byte-for-byte what a fresh clone (the
# buildbot's clobbered checkout) holds: untracked local state — caches, dist,
# .turbo, .env.prod, dev-run data, working notes — never crosses into the
# copy, and the dpkg source tree inherits the same hygiene by construction.
# Tar pipe from the NUL-delimited ls-files list (no rsync dependency). One
# exclusion remains on top of the index: env files — tracked or not, build
# inputs never vary by host and nothing in the build reads them (npm ci and
# the turbo build are env-free phases).
log "copying repo into $SRC (tracked files only)"
rm -rf "$BUILD"
mkdir -p "$SRC"
git -C "$ROOT" ls-files -z | tar --null -T - --exclude='.env*' -cf - | tar -xf - -C "$SRC"

# The copy is the build input: assert cleanliness anyway (known cache/artifact
# classes + env files must not exist in it).
for junk in .git build node_modules .turbo dist .env.dev .env.prod \
            packages/shared/node_modules packages/server/api/node_modules; do
    test ! -e "$SRC/$junk" || fail "copy-out failed: $SRC/$junk must not exist"
done
ok "copy-out clean"

# --- 2. derive npm-compatible manifests inside the copy ------------------------
# The repo is bun-canonical (workspace:* / resolutions); npm rejects both.
# The derivation is mechanical and happens ONLY inside build/source — the
# repo working tree stays pristine (see the header of workspace-to-file.cjs).
log "deriving npm manifests (overrides<-resolutions, workspace:*->file:)"
node scripts/workspace-to-file.cjs apply "$SRC"

# --- 3. package-lock.json — three-state ----------------------------------------
# A COMMITTED package-lock.json is the source of truth on the npm path (bun
# users ignore it): the buildbot never silently adopts a fresh registry
# state. The lock maps the DERIVED npm shape (overrides + file: links), so
# regenerating it is deliberately tied to a REFRESH_LOCK run and a commit.
if [ "${REFRESH_LOCK:-0}" = "1" ]; then
    log "REFRESH_LOCK=1 — regenerating package-lock.json (npm install --package-lock-only)"
    (cd "$SRC" && npm install --package-lock-only --ignore-scripts --no-fund --no-audit)
    cp -f "$SRC/package-lock.json" "$LOCK_OUT"
    ok "lock regenerated -> build/package-lock.json"
    echo "commit it to the repo root: cp build/package-lock.json package-lock.json && git add package-lock.json"
elif [ -f "$ROOT/package-lock.json" ]; then
    cp -f "$ROOT/package-lock.json" "$SRC/package-lock.json"
    log "using committed package-lock.json (REFRESH_LOCK=1 to regenerate)"
else
    fail "package-lock.json is not committed — run REFRESH_LOCK=1 $(basename "$0") once, commit build/package-lock.json to the repo root, then rerun"
fi

# --- 4. full dependency install -------------------------------------------------
# REDISMS_DISABLE_POSTINSTALL=1 matches the Docker build: the redis client's
# postinstall musl/glibc probe must not run on Debian (redis comes from the
# system package).
log "npm ci (full workspace install)"
(cd "$SRC" && REDISMS_DISABLE_POSTINSTALL=1 npm ci --no-fund --no-audit)
ok "node_modules ready"

# --- 5. build --------------------------------------------------------------------
log "npx turbo build (web, engine, api, worker, all bundled qadams)"
(cd "$SRC" && npx turbo run build --filter=web --filter=@aiqadam/engine --filter=api \
    --filter=worker --filter='@aiqadam/qadam-*')
test -f "$SRC/packages/server/api/dist/src/bootstrap.js"     || fail "api build output missing"
test -f "$SRC/packages/server/worker/dist/src/bootstrap.js"  || fail "worker build output missing"
test -d "$SRC/dist/packages/web"                             || fail "web build output missing"
test -d "$SRC/dist/packages/engine"                          || fail "engine build output missing"
ok "builds verified"

# --- 6. manifests (exact Dockerfile commands) -------------------------------------
(cd "$SRC" && npx tsx packages/server/engine/src/scripts/write-qadam-dist-index.ts packages/qadams)
test -s "$SRC/packages/qadams/dist-index.json" || fail "dist-index.json was not written"

(cd "$SRC" && node -e "\
  const {getMigrations} = require('./packages/server/api/dist/src/app/database/postgres-connection');\
  const names = getMigrations().map(M => new M().name);\
  process.stdout.write(JSON.stringify(names));\
" > packages/server/api/dist/src/migration-manifest.json)
test -s "$SRC/packages/server/api/dist/src/migration-manifest.json" || fail "migration-manifest.json was not written"

(cd "$SRC" && node packages/server/api/dist/src/scripts/write-bundled-qadams-manifest.js packages/qadams)
test -s "$SRC/packages/qadams/bundled-qadams-metadata.json" || fail "bundled-qadams-metadata.json was not written"
ok "manifests ready"

# --- 7. payload manifests ----------------------------------------------------------
# The .deb ships the repo's OWN manifests (bun-canonical workspace:*): copy
# them verbatim over the derived ones left inside the copy before staging,
# then byte-verify every one of them (tracked package.json files only —
# node_modules/dist trees hold thousands of vendored package.jsons).
log "restoring repo manifests over the copy (payload ships workspace:* specs)"
cp -f "$ROOT/package.json" "$SRC/package.json"
(cd "$ROOT" && find packages \( -path '*/node_modules/*' -o -path '*/dist/*' \) -prune \
    -o -name 'package.json' -type f -print0) \
    | while IFS= read -r -d '' f; do
        cp -f "$ROOT/$f" "$SRC/$f" \
            || { echo "payload manifest restore failed: $f" >&2; exit 1; }
        cmp -s "$ROOT/$f" "$SRC/$f" \
            || { echo "payload manifest differs from the repo: $f" >&2; exit 1; }
    done \
    || fail "payload manifest restore failed"

# --- 8. stage ----------------------------------------------------------------------
STAGE="$SRC/debian/prebuild/usr"
TREE="$STAGE/lib/qadam-flow"
log "staging payload into build/source/debian/prebuild/usr"
rm -rf "$SRC/debian/prebuild"
mkdir -p "$TREE" "$STAGE/share/qadam-flow" "$STAGE/local/etc"

cp -a "$SRC/node_modules" "$TREE/node_modules"
cp -a "$SRC/packages" "$TREE/packages"
# dist ships WITHOUT the web build — Debian FHS puts the frontend under
# /usr/share/qadam-flow/web and dh_link symlinks dist/packages/web to it.
cp -a "$SRC/dist" "$TREE/dist"
rm -rf "$TREE/dist/packages/web"
cp -a "$SRC/dist/packages/web" "$STAGE/share/qadam-flow/web"

for f in package.json bun.lock bunfig.toml .npmrc LICENSE NOTICE; do
    test -f "$SRC/$f" || fail "root file missing in the copy: $f"
    install -m 0644 "$SRC/$f" "$TREE/$f"
done

cp -a "$SRC/packages/server/api/src/assets/default.cf" "$STAGE/local/etc/isolate"

# Close the loop: the tree debian/rules expects is reachable and complete.
test -f "$STAGE/lib/qadam-flow/packages/server/api/dist/src/bootstrap.js" \
    || fail "staged tree incomplete (bootstrap.js missing)"

ok "staged $(du -sh "$SRC/debian/prebuild" | cut -f1) under build/source/debian/prebuild"
echo
echo "Next:"
echo "  ( cd build/source && dpkg-buildpackage -us -uc -b )"
echo "  mkdir -p build/deb && mv build/qadam-flow_* build/deb/"
