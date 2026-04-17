require_relative "lib/agent_sandbox/version"

Gem::Specification.new do |spec|
  spec.name        = "agent_sandbox"
  spec.version     = AgentSandbox::VERSION
  spec.authors     = ["Lucas Domeij"]
  spec.summary     = "Sandboxed shell + filesystem for AI agents, inspired by @cloudflare/sandbox."
  spec.description = "Give an AI agent a disposable computer: run shell commands, read/write files, expose ports. Pluggable backends (Docker today, E2B/Cloudflare later)."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.files = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]
end
