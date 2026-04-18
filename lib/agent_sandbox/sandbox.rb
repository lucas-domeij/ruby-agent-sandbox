module AgentSandbox
  class ExecResult
    attr_reader :stdout, :stderr, :status
    def initialize(stdout:, stderr:, status:)
      @stdout = stdout
      @stderr = stderr
      @status = status
    end

    def success? = status.zero?
  end

  class Sandbox
    def initialize(backend)
      @backend = backend
      @started = false
    end

    def start
      return self if @started
      @backend.start
      @started = true
      self
    end

    def exec(command, check: false)
      start
      result = @backend.exec(command)
      raise ExecError.new(status: result.status, stdout: result.stdout, stderr: result.stderr) if check && !result.success?
      result
    end

    def spawn(command)
      # Capability check before `start` so unsupported backends don't leave an
      # orphaned remote sandbox running until its timeout.
      unless backend_supports?(:spawn)
        raise UnsupportedOperation,
              "#{@backend.class.name} does not support spawn (use exec, or switch backend)"
      end
      start
      @backend.spawn(command)
    end

    def write_file(path, content)
      start
      @backend.write_file(path, content)
    end

    def read_file(path)
      start
      @backend.read_file(path)
    end

    def port_url(port)
      @backend.port_url(port)
    end

    def stop
      # Always invalidate wrapper start-state and delegate, even on retry.
      # Backends are expected to be idempotent (Docker rm always runs;
      # E2B short-circuits when @sandbox_id is nil). Without this, a failed
      # backend cleanup would leave the wrapper unable to retry stop.
      @started = false
      @backend.stop
    end

    # Auto-start, yield, auto-stop. Cleanup runs on normal return, on
    # exceptions, and on non-local exits (return/break/throw). If both the
    # block and cleanup raise, the original block error is re-raised
    # untouched and cleanup_error is attached as `cause` so neither
    # failure is silently lost.
    def open
      start
      block_error = nil
      begin
        yield self
      rescue => e
        block_error = e
        raise
      ensure
        begin
          stop
        rescue => cleanup_error
          if block_error
            # Clone via Exception#exception so we preserve class, message,
            # backtrace, and all instance vars (matters for ExecError /
            # HttpError, which use kwarg-only initializers). We do NOT use
            # the `cause` slot — that belongs to the block error's original
            # chain. Cleanup is exposed via a singleton #cleanup_error
            # accessor so callers can reach it without losing root cause.
            copy = block_error.exception(block_error.message)
            copy.set_backtrace(block_error.backtrace) if block_error.backtrace
            copy.define_singleton_method(:cleanup_error) { cleanup_error }
            raise copy
          else
            raise
          end
        end
      end
    end
    alias_method :with, :open

    private

    def backend_supports?(capability)
      return @backend.supports?(capability) if @backend.respond_to?(:supports?)
      @backend.respond_to?(capability)
    end
  end
end
