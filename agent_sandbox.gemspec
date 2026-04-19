require_relative "lib/agent_sandbox/version"

Gem::Specification.new do |spec|
  spec.name        = "agent_sandbox"
  spec.version     = AgentSandbox::VERSION
  spec.authors     = ["Lucas Domeij"]
  spec.summary     = "Sandboxed shell + filesystem for AI agents, inspired by @cloudflare/sandbox."
  spec.description = "Give an AI agent a disposable computer: run shell commands, read/write files, expose ports. Pluggable backends (Docker today, E2B/Cloudflare later)."
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/lucas-domeij/ruby-agent-sandbox"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata = {
    "homepage_uri"          => spec.homepage,
    "source_code_uri"       => spec.homepage,
    "bug_tracker_uri"       => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE*"]
  spec.require_paths = ["lib"]

  # `ruby_llm` is an optional integration — only needed if you call
  # `AgentSandbox.ruby_llm_tools(sandbox)` or `AgentSandbox.browser_tools(sandbox)`.
  # Kept out of runtime deps so the gem stays light; add it to your own
  # Gemfile if you want the tool adapters.
  spec.add_development_dependency "ruby_llm", ">= 1.0"
  spec.add_development_dependency "rake",     ">= 13.0"
end
