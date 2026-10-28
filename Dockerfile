# Bakes the DAB config into the image for deploy to the AWS k8s cluster.
# Pin the tag for prod (do not float :latest). Connection strings + JWT come from env at runtime.
# Version pin and its rationale: docs/ci-cd-dev.md §2.
FROM mcr.microsoft.com/azure-databases/data-api-builder:2.0.9

WORKDIR /App
# Base config + all environment overlays (dab-config.<Env>.json), which DAB_ENVIRONMENT selects at
# runtime. An overlay MUST be in the image or DAB falls back to the base config.
COPY dab-config*.json ./
COPY config ./config

# The base image defines APP_UID=1654 but never issues USER, so it would run as root. The chart
# pins the same uid; keep the two in sync. See docs/ci-cd-dev.md §6a.
USER $APP_UID

EXPOSE 5000
# With no args this serves /App/dab-config.json. Selecting any OTHER config requires overriding the
# command to run the CLI — a bare `args:` flag is silently ignored. See docs/ci-cd-dev.md §2.
