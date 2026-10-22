#!/bin/bash
echo "Starting RGW Heads Visualizer..."
# Source conda initialization script
source ~/miniforge3/etc/profile.d/conda.sh || source ~/miniconda3/etc/profile.d/conda.sh || source ~/anaconda3/etc/profile.d/conda.sh
conda activate flopy_env

# Run the shiny app
echo "=========================================================="
echo "App is starting! Open this link in your browser:"
echo "http://127.0.0.1:8888"
echo "=========================================================="
# Optional map keys (e.g. ARCGIS_API_KEY for the Esri satellite base map) from
# a gitignored .env. Write values UNQUOTED (docker --env-file compatibility).
# Map keys shared by all apps (ARCGIS_API_KEY, LINZ_BASEMAPS_KEY) from the
# monorepo root, then this app's own .env. Both optional, both gitignored.
if [ -f ../../.env.maps ]; then
  set -a
  . ../../.env.maps
  set +a
fi
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

# Review bundles (local use only): ./run_app.sh --bundles <folder> lists every
# bundle (a folder with manifest.json) under <folder> in "1. Data Uploads".
# Same as setting CF_BUNDLE_ROOT. Without it the picker is hidden.
if [ "${1:-}" = "--bundles" ]; then
  if [ -z "${2:-}" ] || [ ! -d "$2" ]; then
    echo "Usage: ./run_app.sh --bundles <folder holding review bundles>"
    exit 1
  fi
  export CF_BUNDLE_ROOT="$(cd "$2" && pwd)"
fi
[ -n "${CF_BUNDLE_ROOT:-}" ] && echo "Review bundles from: $CF_BUNDLE_ROOT"

# Refuse to start a second copy: two apps cannot share port 8888, and R's
# "address already in use" error does not say which process to stop.
PORT=8888
if command -v ss >/dev/null 2>&1 && ss -ltn "sport = :$PORT" | grep -q ":$PORT"; then
  HOLDER=$(ss -ltnp "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
  STATE=$( [ -n "$HOLDER" ] && ps -o stat= -p "$HOLDER" 2>/dev/null | cut -c1 )
  if [ "$STATE" = "T" ]; then
    # Ctrl+Z pauses instead of stopping: the paused app keeps the port but
    # serves nothing, and ignores a plain kill until it is resumed.
    echo "An earlier copy is PAUSED (Ctrl+Z was pressed instead of Ctrl+C) and still holds port $PORT."
    echo "In that terminal: fg, then Ctrl+C.   Or from anywhere: kill -CONT $HOLDER; kill $HOLDER"
  else
    echo "The app is already running on http://127.0.0.1:$PORT${HOLDER:+ (process $HOLDER)}."
    echo "Use that one, or stop it first: Ctrl+C in its terminal${HOLDER:+, or: kill $HOLDER}"
  fi
  exit 1
fi

Rscript -e "shiny::runApp('app.R', port=8888, host='127.0.0.1', launch.browser=FALSE)"
