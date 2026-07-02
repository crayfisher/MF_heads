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
Rscript -e "shiny::runApp('app.R', port=8888, host='127.0.0.1', launch.browser=FALSE)"
