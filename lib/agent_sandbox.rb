require "agent_sandbox/version"
require "agent_sandbox/sandbox"
require "agent_sandbox/backends/docker"
require "agent_sandbox/backends/e2b"

module AgentSandbox
  class Error < StandardError; end
  # Raised when the selected backend does not implement a requested capability
  # (e.g. E2B spawn). Kept as an Error subclass so callers' `rescue
  # AgentSandbox::Error` paths catch it — unlike NotImplementedError, which is
  # a ScriptError and escapes normal rescues.
  class UnsupportedOperation < Error; end
  class ExecError < Error
    attr_reader :status, :stdout, :stderr
    def initialize(status:, stdout:, stderr:)
      @status = status
      @stdout = stdout
      @stderr = stderr
      super("exec failed with status #{status}: #{stderr.strip}")
    end
  end

  BACKENDS = {
    docker: Backends::Docker,
    e2b: Backends::E2B
  }

  def self.new(backend: :docker, **opts)
    klass = BACKENDS.fetch(backend) { raise Error, "unknown backend #{backend.inspect}" }
    Sandbox.new(klass.new(**opts))
  end

  def self.ruby_llm_tools(sandbox)
    require "agent_sandbox/ruby_llm_tools"
    RubyLLMTools.build(sandbox)
  end
end
