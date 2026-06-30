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

cd "$(dirname "$0")"

echo "==> git pull"
git pull --ff-only || echo "   (not a fast-forward / no remote change — using local code)"

echo "==> docker build -t ${IMAGE} ."
docker build -t "${IMAGE}" .

echo "==> recreate container ${CONTAINER}"
docker rm -f "${CONTAINER}" 2>/dev/null || true
docker run -d --restart unless-stopped --name "${CONTAINER}" \
  -p "${HOST_PORT}:${CTR_PORT}" "${IMAGE}"

echo "==> verify"
docker ps --filter "name=${CONTAINER}"
if [ "$(docker exec "${CONTAINER}" grep -c app-beta-badge "${APP_PATH}" || true)" -ge 1 ]; then
  echo "   new code present in container: OK"
else
  echo "   WARNING: expected marker not found in ${APP_PATH} — check the build."
fi

echo "Done -> http://localhost:${HOST_PORT}  (hard-refresh the browser if it looks old)"
