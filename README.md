# agent_sandbox

Give an AI agent a disposable computer.

A Ruby gem that lets you hand an LLM a shell, a filesystem, and a network
port, without letting it anywhere near your actual machine. Two swappable
backends with identical APIs: **Docker** (local, free, hardened by default)
and **E2B** (cloud Firecracker microVMs).

Think `@cloudflare/sandbox` for Ruby.

## Why

LLM agents want to run code. Running that code on your laptop or your
production box is a bad idea. `agent_sandbox` gives them a throwaway
environment instead — they can `rm -rf /`, run a webserver, pip install
whatever — and when they're done you just drop the sandbox.

## Install

```ruby
# Gemfile
gem "agent_sandbox", git: "https://github.com/lucas-domeij/ruby-agent-sandbox"
```

Docker backend needs the Docker daemon running. E2B needs an API key from
[e2b.dev](https://e2b.dev).

## Quick start — Docker

```ruby
require "agent_sandbox"

sandbox = AgentSandbox.new(backend: :docker, image: "ruby:3.3-slim")
sandbox.with do |sb|
  sb.write_file("/workspace/hello.rb", 'puts "hej från containern"')
  result = sb.exec("ruby /workspace/hello.rb")
  puts result.stdout  # => "hej från containern\n"
end
```

Running a webserver inside the sandbox and calling it from the host:

```ruby
sandbox = AgentSandbox.new(backend: :docker, ports: [8080])
sandbox.with do |sb|
  sb.spawn("ruby -run -e httpd /workspace -p 8080")
  sleep 1
  puts sb.port_url(8080)  # => "http://127.0.0.1:54321"
end
```

## Quick start — E2B (cloud)

```ruby
sandbox = AgentSandbox.new(backend: :e2b, api_key: ENV["E2B_API_KEY"])
sandbox.with do |sb|
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

## API

```ruby
sandbox.exec(cmd)           # => ExecResult(stdout:, stderr:, status:)
sandbox.exec(cmd, check: true)  # raises ExecError on non-zero
sandbox.spawn(cmd)          # fire-and-forget background process
sandbox.write_file(path, content)
sandbox.read_file(path)     # => String
sandbox.port_url(port)      # => URL to reach a port published by the sandbox
sandbox.stop                # tear down
sandbox.with { |sb| ... }   # auto-start + auto-stop
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

## License

MIT
