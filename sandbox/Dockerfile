# Use the SDK-shipped base image so versions stay in lockstep with
# @cloudflare/sandbox (Architecture A: preview/dev only; agents run in Herdr).
FROM docker.io/cloudflare/sandbox:0.7.21

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && (corepack enable || true)

WORKDIR /workspace
