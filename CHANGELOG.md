# Changelog

All notable changes to `agent_sandbox` are documented in this file. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0]

Initial release.

### Added

- **Core sandbox API**: `AgentSandbox.new(backend: …)` with `exec`,
  `spawn`, `write_file`, `read_file`, `port_url`, `open { … }` block form,
  and explicit `start` / `stop` for long-lived patterns.
- **Docker backend**: local containers via `docker` CLI, port forwarding,
  optional `--user nobody` hardening, `memory:` limits.
- **E2B backend**: cloud sandboxes via E2B's control plane + envd
  (`exec`, `read_file`, `write_file`, `port_url`). Connect-RPC streaming
  for `exec`. Retries with backoff on idempotent requests, structured 404
  validation on `stop` so failed deletes can't orphan running sandboxes.
- **RubyLLM tool adapters** (`AgentSandbox.ruby_llm_tools(sb)`): four
  tools — `exec`, `write_file`, `read_file`, `port_url` — ready to plug
  into a `RubyLLM::Chat`.
- **Browser tools** (`AgentSandbox.browser_tools(sb)`): 11 tools wrapping
  Vercel's `agent-browser` CLI so an LLM can drive real Chromium inside
  the sandbox — `open`, `snapshot`, `click`, `fill`, `get_text`, `wait`,
  `back`, `reload`, `eval`, `screenshot`, `read_image`. Vision tools
  (`screenshot`, `read_image`) make an internal multimodal sub-call
  (default `gpt-5`, configurable via arg or `AGENT_SANDBOX_VISION_MODEL`)
  so the caller's tool loop only ever sees text. `read_image` fetches
  through the live page session (so cookies/auth headers carry over) and
  rejects non-image responses before calling the vision model.
- **Reference images**:
  - `docker/browser.Dockerfile` — Debian + chromium + agent-browser,
    multi-arch (amd64/arm64).
  - `e2b/browser/e2b.Dockerfile` — same stack built as an E2B template.
- **Error hierarchy**: `AgentSandbox::Error`, `AuthError`, `TimeoutError`,
  `ConnectError`, `ServerError`, `HttpError`, `SandboxNotFound`,
  `UnsupportedOperation`, `CleanupError`.

[Unreleased]: https://github.com/lucas-domeij/ruby-agent-sandbox/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/lucas-domeij/ruby-agent-sandbox/releases/tag/v0.1.0
