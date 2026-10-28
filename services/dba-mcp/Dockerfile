# The DBA MCP server. dbatools is baked in rather than installed at boot: a cold
# Install-Module on start turns a container restart into a multi-minute outage, and
# pins nothing.
FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

# Node 22 (the server declares engines >= 22).
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates gnupg \
 && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

RUN pwsh -NoProfile -Command \
    "Set-PSRepository PSGallery -InstallationPolicy Trusted; \
     Install-Module dbatools -RequiredVersion 2.7.2 -Scope AllUsers -Force; \
     Import-Module dbatools -ErrorAction Stop; \
     Write-Host ('dbatools ' + (Get-Module dbatools).Version)"

WORKDIR /app
# npm ci (not npm install): it installs exactly what package-lock.json pins and refuses
# to proceed if package.json and the lockfile disagree. npm install re-resolves semver
# ranges (mssql ^11.0.1, @modelcontextprotocol/sdk ^1.12.0, ...) against the registry on
# every build, silently drifting from what was tested. Install everything (including
# devDeps) up front - esbuild is a devDependency and is needed for the bundle step below.
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY tsconfig.json ./
COPY src ./src
RUN npx esbuild src/index.ts \
      --platform=node --target=node22 --bundle --packages=external --outfile=dist/index.js \
 && npm prune --omit=dev

ENV MCP_TRANSPORT=http \
    MCP_BIND_HOST=0.0.0.0 \
    PORT=3000 \
    TOOLSET=dba
EXPOSE 3000

# Non-root: the server needs no write access to its own image.
RUN useradd --system --uid 10001 --create-home dbamcp
USER 10001

CMD ["node", "dist/index.js"]
