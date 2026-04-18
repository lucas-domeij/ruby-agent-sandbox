require "agent_sandbox/version"
require "agent_sandbox/sandbox"
require "agent_sandbox/backends/docker"
require "agent_sandbox/backends/e2b"

module AgentSandbox
  class Error < StandardError; end
  class UnsupportedOperation < Error; end
  class AuthError < Error; end
  class SandboxNotFound < Error; end
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

  # Raised when BOTH the user's block AND sandbox cleanup fail. The `cause`
  # slot carries the original block error (so its own cause chain survives
  # untouched, and default exception reporting — full_message, APMs, log
  # handlers that traverse `cause` — surfaces the whole story). The cleanup
  # failure is exposed via #cleanup_error for callers that need it
  # individually.
  class CleanupError < Error
    attr_reader :block_error, :cleanup_error
    def initialize(block_error, cleanup_error)
      @block_error = block_error
      @cleanup_error = cleanup_error
      super(
        "sandbox block raised #{block_error.class}: #{block_error.message}; " \
        "then cleanup raised #{cleanup_error.class}: #{cleanup_error.message}"
      )
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
