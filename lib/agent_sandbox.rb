require "agent_sandbox/version"
require "agent_sandbox/sandbox"
require "agent_sandbox/backends/docker"
require "agent_sandbox/backends/e2b"

module AgentSandbox
  # Base error. Callers can `rescue AgentSandbox::Error` to catch everything
  # this library raises (including the specialised subclasses below).
  class Error < StandardError; end

  # `Sandbox#spawn` hit a backend that does not implement spawn yet (e.g. E2B).
  class UnsupportedOperation < Error; end

  # Raised by backends when credentials are missing, invalid, or rejected by
  # the remote control plane.
  class AuthError < Error; end

  # The remote referenced a sandbox/template that no longer exists or was
  # never created.
  class SandboxNotFound < Error; end

  # Network timeout from either the control plane or envd. Separate from
  # ConnectError so callers can retry these specifically.
  class TimeoutError < Error; end

  # Socket-level failure reaching the remote (DNS, refused, TLS handshake).
  class ConnectError < Error; end

  # envd or the control plane returned a 5xx. Retried a few times by the
  # backend before it bubbles up.
  class ServerError < Error; end

  # Represents an HTTP response that the backend decided was unrecoverable —
  # e.g. a 4xx the caller screwed up. Includes status + body for debugging.
  class HttpError < Error
    attr_reader :status, :body
    def initialize(status:, body:, message: nil)
      @status = status
      @body = body
      super(message || "HTTP #{status}: #{body.to_s[0, 500]}")
    end
  end

  # Raised by `Sandbox#exec(cmd, check: true)` when the command exited non-zero.
  # Still an Error so a blanket rescue catches it, but holds the ExecResult
  # fields so callers can inspect.
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
