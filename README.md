# agent_sandbox

[![Gem Version](https://img.shields.io/gem/v/agent_sandbox)](https://rubygems.org/gems/agent_sandbox)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)

Give an AI agent a disposable computer.

A Ruby gem that lets you hand an LLM a shell, a filesystem, and a network
port, without letting it anywhere near your actual machine. Two swappable
backends with identical APIs: **Docker** (local, free, hardened by default)
and **E2B** (cloud Firecracker microVMs).

Think [`@cloudflare/sandbox`](https://www.npmjs.com/package/@cloudflare/sandbox)
or [`@vercel/sandbox`](https://www.npmjs.com/package/@vercel/sandbox) — but
for Ruby.

## Why

LLM agents want to run code. Running that code on your laptop or your
production box is a bad idea. `agent_sandbox` gives them a throwaway
environment instead — they can `rm -rf /`, run a webserver, pip install
whatever — and when they're done you just drop the sandbox.

## Install

```sh
bundle add agent_sandbox
# or
gem install agent_sandbox
```

Docker backend needs the Docker daemon running. E2B needs an API key from
[e2b.dev](https://e2b.dev). The RubyLLM and browser tool adapters require
`ruby_llm` — add it to your Gemfile if you want them.

## Quick start — Docker

```ruby
require "agent_sandbox"

sandbox = AgentSandbox.new(backend: :docker, image: "ruby:3.3-slim")
sandbox.open do |sb|
  sb.write_file("/workspace/hello.rb", 'puts "hej från containern"')
  result = sb.exec("ruby /workspace/hello.rb")
  puts result.stdout  # => "hej från containern\n"
end
```

Running a webserver inside the sandbox and calling it from the host:

```ruby
sandbox = AgentSandbox.new(backend: :docker, ports: [8080])
sandbox.open do |sb|
  sb.spawn("ruby -run -e httpd /workspace -p 8080")
  sleep 1
  puts sb.port_url(8080)  # => "http://127.0.0.1:54321"
end
```

## Quick start — E2B (cloud)

```ruby
sandbox = AgentSandbox.new(backend: :e2b, api_key: ENV["E2B_API_KEY"])
sandbox.open do |sb|
  sb.write_file("/home/user/data.json", '{"x": 1}')
  result = sb.exec("cat /home/user/data.json | jq .x")
  puts result.stdout  # => "1\n"
end
```

Same API, different substrate. Ports published by the sandbox are
reachable at `https://<port>-<sandbox_id>.e2b.app`.

## Drop into RubyLLM

The gem ships tool adapters so an LLM can drive the sandbox itself:

```ruby
require "ruby_llm"
require "agent_sandbox"

sandbox = AgentSandbox.new(backend: :docker)
sandbox.start

RubyLLM.chat(model: "gpt-4o-mini")
  .with_tools(*AgentSandbox.ruby_llm_tools(sandbox))
  .ask("Write a Python script that prints the first 10 primes, then run it.")

sandbox.stop
```

The LLM gets four tools: `exec`, `write_file`, `read_file`, `port_url`.
It decides when to call them.

## Browser tools

For agents that need to drive a real website — scrape, fill forms, click
through flows — the gem also ships adapters around [Vercel's
`agent-browser`](https://github.com/vercel-labs/agent-browser) CLI:

```ruby
sandbox = AgentSandbox.new(
  backend: :docker, image: "agent-sandbox-browser",
  hardened: false, memory: "2g"
)

sandbox.open do |sb|
  RubyLLM.chat(model: "gpt-5")
    .with_tools(*AgentSandbox.browser_tools(sb))
    .ask("Hitta Lidls extrapriser denna vecka")
end
```

The LLM gets 11 tools backed by a real Chromium running in the sandbox:

| Tool | What it does |
| --- | --- |
| `open` | Navigate to a URL |
| `snapshot` | Accessibility-tree snapshot with `@e1/@e2/…` refs |
| `click` / `fill` / `get_text` | Drive elements by ref |
| `wait` | Wait for ms or text |
| `back` / `reload` | Navigation |
| `eval` | Run arbitrary JS in the page |
| `screenshot` | PNG of the viewport → vision-model description |
| `read_image` | Download any image URL → vision-model description |

`screenshot` and `read_image` make a secondary multimodal call (default
`gpt-5`, override with `browser_tools(sb, vision_model: "…")` or
`AGENT_SANDBOX_VISION_MODEL`) so the caller's tool loop only ever sees text.

### When to use which

- Product listings, search results, forms → `snapshot` + `click`/`get_text`.
  Fast, cheap, exact.
- Canvas-rendered flipbooks / brochure viewers → `eval` to discover the
  underlying `<img>` URLs, then `read_image` on each page. Much higher
  resolution than a viewport `screenshot`, and skips browser chrome.
- JS-heavy SPAs where elements don't show up in `snapshot` → `eval` to poke
  at `window.__NEXT_DATA__`, Redux state, or fetch intercepts.
- Truly canvas-only UIs (maps, charts) → `screenshot` with a `focus:` hint.

### The image

`docker/browser.Dockerfile` layers `agent-browser` + distro chromium on top
of `debian:bookworm-slim`. Multi-arch (amd64/arm64). Build it once:

```sh
docker build -f docker/browser.Dockerfile -t agent-sandbox-browser .
```

Chrome needs `hardened: false` (it writes under `/root`) and `memory: "2g"`.
Those two args in the sandbox constructor above are load-bearing.

### Running on E2B

The same browser tools work against the `:e2b` backend — only the template
has to exist in your E2B account. `e2b/browser/e2b.Dockerfile` is the
reference image:

```sh
cd e2b/browser
e2b auth login           # one-time
e2b template create agent-sandbox-browser --memory-mb 2048 --cpu-count 2
```

Then flip the backend:

```ruby
sandbox = AgentSandbox.new(backend: :e2b, template: "agent-sandbox-browser")

sandbox.open do |sb|
  RubyLLM.chat(model: "gpt-5")
    .with_tools(*AgentSandbox.browser_tools(sb))
    .ask("What is the title of example.com?")
end
```

E2B runs the sandbox as user `user` (not root), so the Docker-specific
`hardened: false` / `memory: "2g"` knobs don't apply — memory is set at
template-build time via `--memory-mb`.

## Sandbox lifecycle

`exec` / `write_file` / `read_file` all auto-start the sandbox, so the only
question is **who owns `stop`**. Three common patterns:

```ruby
# Per-task: fresh sandbox per prompt. Cheap, no state leak, no context
# carried between turns. `open` auto-starts AND auto-stops.
AgentSandbox.new(backend: :docker).open { |sb| agent.handle(sb, prompt) }

# Per-conversation: one sandbox for the whole chat. Agent can build on
# earlier work (installed deps, written files). You own `stop`.
sb = AgentSandbox.new(backend: :e2b).start
begin
  loop { chat.ask(gets.chomp) }
ensure
  sb.stop
end

# Pool: reuse N sandboxes across many tasks. Fastest per-request, but
# you're responsible for resetting state between tasks.
pool = 5.times.map { AgentSandbox.new(backend: :e2b).start }
```

Per-task is the safe default. Go per-conversation when the agent genuinely
needs continuity (e.g. iterating on a project). Pool only when throughput
matters more than isolation.

## API

```ruby
sandbox.exec(cmd)           # => ExecResult(stdout:, stderr:, status:)
sandbox.exec(cmd, check: true)  # raises ExecError on non-zero
sandbox.spawn(cmd)          # fire-and-forget background process
sandbox.write_file(path, content)
sandbox.read_file(path)     # => String
sandbox.port_url(port)      # => URL to reach a port published by the sandbox
sandbox.stop                # tear down
sandbox.open { |sb| ... }   # auto-start + auto-stop (alias: #with)
```

## Hardening (Docker backend)

Defaults — all opt-out:

| Flag | Default | Why |
| --- | --- | --- |
| `--user nobody` | yes | No root inside the container |
| `--cap-drop ALL` | yes | Strip Linux capabilities |
| `--security-opt no-new-privileges` | yes | Block setuid escalation |
| `--read-only` rootfs + tmpfs for `/workspace` | yes | Agent can't persist anywhere surprising |
| `--memory 512m` | yes | OOM before DoS |
| `--pids-limit 256` | yes | Fork-bomb cap |
| `--cpus 1.0` | yes | Single-core |
| `--network bridge` | yes | Internet for `gem install` etc. Use `network: :none` to block |
| Ports bound to `127.0.0.1` | yes | Not LAN-reachable. Pass `port_bind: "0.0.0.0"` to expose |

Pass `hardened: false` to turn it all off, or override individual flags.

## Backend comparison

| | Docker | E2B |
| --- | --- | --- |
| Where it runs | Your machine | Firecracker microVM in the cloud |
| Cost | Free | Pay-per-second |
| Isolation | Linux namespaces | Firecracker hypervisor (stronger) |
| Startup | ~1s | ~150ms (they pre-warm) |
| Need Docker daemon | Yes | No |
| `spawn` (background procs) | Yes | Not yet — raises `UnsupportedOperation` |
| Good for | Dev, local agents, CI | Production, untrusted user code |

## Status

Working prototype. Kicked the tires with a real LLM driving a real
sandbox — it works. That said:

- Only Docker + E2B wired up so far
- E2B `spawn` needs tagged Connect-RPC before it'll work
- No CI, no Rubygems release yet
- API may still shift

## Prior art

- [`@cloudflare/sandbox`](https://www.npmjs.com/package/@cloudflare/sandbox)
  — Cloudflare's Workers-hosted sandbox SDK. The direct inspiration for this
  gem's API shape.
- [`@vercel/sandbox`](https://www.npmjs.com/package/@vercel/sandbox) —
  Vercel's ephemeral compute for running untrusted bash / code from agents.
- [E2B](https://e2b.dev) — Firecracker microVMs as a service. Powers the
  `:e2b` backend here.

## License

MIT
