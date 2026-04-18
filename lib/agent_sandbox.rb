require "agent_sandbox/version"
require "agent_sandbox/sandbox"
require "agent_sandbox/backends/docker"
require "agent_sandbox/backends/e2b"

module AgentSandbox
  class Error < StandardError; end
  class UnsupportedOperation < Error; end
  class AuthError < Error; end
  # SandboxNotFound carries the raw HTTP status + body so callers (e.g.
  # E2B#stop deciding whether a 404 really means "sandbox gone") can
  # inspect the structured provider response instead of string-matching
  # Exception#message.
  class SandboxNotFound < Error
    attr_reader :status, :body
    def initialize(message = nil, status: nil, body: nil)
      @status = status
      @body = body
      super(message)
    end
  end
  class TimeoutError < Error; end
  class ConnectError < Error; end
  class ServerError < Error; end

  class HttpError < Error
    attr_reader :status, :body
    def initialize(status:, body:, message: nil)
      @status = status
      @body = body
      super(message || "HTTP #{status}: #{body.to_s[0, 500]}")
    end
  end

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
