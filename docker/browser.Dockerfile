# Browser-capable sandbox image: Debian slim + Vercel's agent-browser CLI
# + Chrome for Testing (downloaded by agent-browser install). Use with
# `image: "agent-sandbox-browser"` and `hardened: false` (Chrome needs
# more than the default 512m memory, and installed browser files live
# under /root which `--user nobody` can't read).
FROM debian:bookworm-slim

ARG AGENT_BROWSER_VERSION=v0.26.0
ARG TARGETARCH

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl && \
    rm -rf /var/lib/apt/lists/*

# Pick the right agent-browser binary for the build platform. Docker
# passes TARGETARCH = amd64 | arm64 | ... — agent-browser publishes
# linux-x64 and linux-arm64 release assets.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64)  asset=agent-browser-linux-x64 ;; \
      arm64)  asset=agent-browser-linux-arm64 ;; \
      *) echo "unsupported arch ${TARGETARCH}"; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/agent-browser \
      "https://github.com/vercel-labs/agent-browser/releases/download/${AGENT_BROWSER_VERSION}/${asset}"; \
    chmod +x /usr/local/bin/agent-browser; \
    agent-browser --version

# Install a Chrome-compatible browser. Chrome For Testing only ships
# linux-x64 builds, so on ARM64 hosts agent-browser's bundled installer
# fails — use the distro's chromium package on every arch for a single
# code path, then point agent-browser at it via env var.
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

CMD ["sh", "-c", "sleep infinity"]
