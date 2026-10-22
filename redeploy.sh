#!/usr/bin/env bash
# Redeploy the RGWheads (MODFLOW heads visualiser) Docker container.
# Pulls the latest code, builds a fresh image, recreates the container, verifies.
# Safe for a first deploy too (the `docker rm -f` no-ops if absent).
#
# NOTE: demo/ is gitignored — make sure it is present locally BEFORE building
#       (build context carries it, not git; see DEPLOYMENT.md §3b).
#
# Usage:  cd ~/apps/RGWheads_oct-quad && ./redeploy.sh
set -euo pipefail

IMAGE="rgw_heads_app"
CONTAINER="rgw_heads"
HOST_PORT="3839"
CTR_PORT="3838"
APP_PATH="/app/app.R"

# Works BOTH in the platform monorepo and in the standalone public mirror,
# because this file is published to the mirror too and must not assume a
# layout that only exists in one of them.
#   monorepo   -> git at the repo root; Docker context is ASSEMBLED
#                 (this app + the shared lib/cf_theme.R) by tools/assemble.sh
#   standalone -> git and Docker context are both this directory, where
#                 lib/cf_theme.R is already a real file
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$(basename "$APP_DIR")"
if [ -x "${APP_DIR}/../../tools/assemble.sh" ]; then
  MONOREPO=1; ROOT="$(cd "${APP_DIR}/../.." && pwd)"
else
  MONOREPO=0; ROOT="$APP_DIR"
fi
cd "$ROOT"

echo "==> git pull"
git pull --ff-only || echo "   (not a fast-forward / no remote change — using local code)"

if [ "$MONOREPO" = 1 ]; then
  echo "==> assemble build context (apps/${APP} + lib/cf_theme.R)"
  CTX="$(mktemp -d)"; trap 'rm -rf "$CTX"' EXIT
  "${ROOT}/tools/assemble.sh" "${APP}" "${CTX}"
else
  CTX="$APP_DIR"
fi

echo "==> docker build -t ${IMAGE} ${CTX}"
docker build -t "${IMAGE}" "${CTX}"

echo "==> recreate container ${CONTAINER}"
docker rm -f "${CONTAINER}" 2>/dev/null || true
# Optional env file for map keys (ARCGIS_API_KEY for the Esri satellite base
# map). Without it the app runs with the OpenStreetMap base map only. Write
# values UNQUOTED: docker --env-file does no shell parsing.
# Map keys shared by all apps live in /etc/crayfisher-maps.env; an app file
# (/etc/mf_heads.env) may add to or override them. Both optional.
ENV_FILE="${ENV_FILE:-/etc/mf_heads.env}"
ENV_ARGS=()
for f in /etc/crayfisher-maps.env "${ENV_FILE}"; do
  if [ -f "$f" ]; then ENV_ARGS+=(--env-file "$f"); echo "   using $f"; fi
done
[ ${#ENV_ARGS[@]} -eq 0 ] && echo "   no env files — Esri base maps disabled (OpenStreetMap only)"
docker run -d --restart unless-stopped --name "${CONTAINER}" \
  ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
  -p "127.0.0.1:${HOST_PORT}:${CTR_PORT}" "${IMAGE}"

echo "==> verify"
docker ps --filter "name=${CONTAINER}"
if [ "$(docker exec "${CONTAINER}" grep -c app-beta-badge "${APP_PATH}" || true)" -ge 1 ]; then
  echo "   new code present in container: OK"
else
  echo "   WARNING: expected marker not found in ${APP_PATH} — check the build."
fi

echo "Done -> http://127.0.0.1:${HOST_PORT} on the server (behind Caddy/Cloudflare for the public URL; hard-refresh the browser if it looks old)"
