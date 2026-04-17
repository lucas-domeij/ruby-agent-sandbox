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
      return unless @started
      @backend.stop
      @started = false
    end

    def open
      start
      yield self
    ensure
      stop
    end
    alias_method :with, :open

    private

    def backend_supports?(capability)
      return @backend.supports?(capability) if @backend.respond_to?(:supports?)
      @backend.respond_to?(capability)
    end
  end
end
