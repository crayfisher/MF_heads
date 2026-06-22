FROM mambaorg/micromamba:latest

# Copy the environment file
COPY --chown=$MAMBA_USER:$MAMBA_USER environment.yml /tmp/environment.yml

# Install the environment directly into base to save space
RUN micromamba install -y -n base -f /tmp/environment.yml && \
    micromamba clean --all --yes

# Copy the application files
COPY --chown=$MAMBA_USER:$MAMBA_USER . /app
WORKDIR /app

# Expose the standard Shiny port
EXPOSE 3838

# Run the app on 0.0.0.0
CMD ["micromamba", "run", "-n", "base", "Rscript", "-e", "shiny::runApp('app.R', host = '0.0.0.0', port = 3838)"]
