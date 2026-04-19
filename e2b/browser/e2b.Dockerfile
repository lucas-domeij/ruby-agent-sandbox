# E2B template: debian + chromium + Vercel's agent-browser CLI.
# Mirrors docker/browser.Dockerfile but targets E2B's x86_64-only
# builder (no TARGETARCH branching). Build with:
#   cd e2b/browser && e2b template create agent-sandbox-browser \
#     --memory-mb 2048 --cpu-count 2
FROM debian:bookworm-slim

ARG AGENT_BROWSER_VERSION=v0.26.0

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /usr/local/bin/agent-browser \
      "https://github.com/vercel-labs/agent-browser/releases/download/${AGENT_BROWSER_VERSION}/agent-browser-linux-x64" && \
    chmod +x /usr/local/bin/agent-browser && \
    agent-browser --version

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      chromium \
      chromium-sandbox \
      fonts-liberation \
      libnss3 \
      libxss1 \
      libasound2 \
    && rm -rf /var/lib/apt/lists/*

ENV AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/chromium

WORKDIR /workspace
