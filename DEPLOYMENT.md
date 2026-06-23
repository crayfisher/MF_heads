# Docker Deployment Guide: RGWheads

This guide covers the architecture, build instructions, and deployment strategies for containerizing the `RGWheads` Shiny Application.

## 1. Architecture

The Docker container is built on top of **`mambaorg/micromamba`** rather than the standard `rocker/shiny` image. 
*   **Why?** Geospatial R packages (`sf`, `stars`, `arrow`) require massive system-level libraries (GDAL, GEOS, PROJ, C++ compilers) that take hours to compile from source in standard Linux environments. 
*   **The Fix:** By using Conda/Micromamba, we instantly download the pre-compiled binary versions of these libraries, reducing build times from hours to minutes.

## 2. Environment Management (`environment.yml`)

The application's dependencies are tracked strictly in `environment.yml`. 
To keep the Docker image small and secure, this file was manually pruned to *only* include production libraries. It excludes local data science utilities (like Jupyter) that were present in the development environment.

**Important Packages included:**
*   `r-base`, `r-shiny`, `r-bslib`, `r-shinymanager`
*   `r-sf`, `r-stars`, `r-arrow`, `r-dplyr`
*   `c-compiler`, `cxx-compiler` (Needed to compile packages from GitHub)

**Special Case: `rdeck`**
The `rdeck` package is **not** available on CRAN or conda-forge. It is a GitHub-only package. 
If you look at the `Dockerfile`, there is a dedicated line using `remotes::install_github('qfes/rdeck')` to compile it from source. This is why the C++ compilers were added to the `environment.yml`.

## 3. Security (shinymanager)

The application is protected behind a login screen using `shinymanager`. 
*   **Username:** `viewer`
*   **Password:** The password is **never** hardcoded into `app.R` or the Docker image. 
*   It securely reads from an environment variable (`APP_PASSWORD`) that you inject at runtime. If you run the app locally in RStudio without Docker, it will default to `rgw_secret` so your local development is not interrupted.

## 4. Building the Image

To build the Docker image, run the following command in the project root (where the `Dockerfile` is located). 
This will read the `.dockerignore` file, ensuring large `data/` files and `.Rhistory` caches are not copied into the image.

```bash
docker build -t rgw_heads_app .
```

## 5. Running the Container

Once built, launch the container using `docker run`. You must explicitly map port `3838` (the Shiny default) and inject your secure password:

**Foreground Mode (For testing and seeing error logs):**
```bash
docker run -p 3838:3838 -e APP_PASSWORD="MySuperSecurePassword123" rgw_heads_app
```

**Detached/Daemon Mode (For production deployment):**
```bash
docker run -d --restart unless-stopped -p 3838:3838 -e APP_PASSWORD="MySuperSecurePassword123" rgw_heads_app
```

Once running, the application will be accessible at: `http://<your-server-ip>:3838` or `http://localhost:3838`.
