require "ruby_llm"

module AgentSandbox
  # Wraps a Sandbox as a set of RubyLLM tools so an LLM can drive it directly.
  #
  #   sandbox = AgentSandbox.new(backend: :docker)
  #   chat = RubyLLM.chat(model: "claude-opus-4-7")
  #   chat.with_tools(*AgentSandbox.ruby_llm_tools(sandbox))
  module RubyLLMTools
    def self.build(sandbox)
      [
        Exec.new(sandbox),
        WriteFile.new(sandbox),
        ReadFile.new(sandbox),
        PortUrl.new(sandbox)
      ]
    end

    class Base < RubyLLM::Tool
      def initialize(sandbox)
        @sandbox = sandbox
        super()
      end
    end

    class Exec < Base
      description "Run a shell command inside the sandbox. Returns stdout, stderr, and exit status."
      param :command, desc: "Shell command to run (sh -c). Example: 'ls -la /workspace'."

      def execute(command:)
        result = @sandbox.exec(command)
        {
          stdout: truncate(result.stdout),
          stderr: truncate(result.stderr),
          status: result.status
        }
      end

      private

      def truncate(str, limit: 8000)
        return str if str.length <= limit
        str[0, limit] + "\n…[truncated #{str.length - limit} chars]"
      end
    end

    class WriteFile < Base
      description "Write text content to a file in the sandbox. Parent directories are created."
      param :path, desc: "Absolute path, e.g. /workspace/app.rb"
      param :content, desc: "Full file contents."

      def execute(path:, content:)
        @sandbox.write_file(path, content)
        { ok: true, path: path, bytes: content.bytesize }
      end
    end

    class ReadFile < Base
      description "Read a text file from the sandbox."
      param :path, desc: "Absolute path inside the sandbox."

      def execute(path:)
        { path: path, content: @sandbox.read_file(path) }
      rescue AgentSandbox::Error => e
        { error: e.message }
      end
    end

    class PortUrl < Base
      description "Get the host URL that maps to a port exposed inside the sandbox. The port must have been declared at sandbox creation."
      param :port, desc: "The container port number, e.g. 8080"

      def execute(port:)
        { url: @sandbox.port_url(port.to_i) }
      rescue AgentSandbox::Error => e
        { error: e.message }
      end
    end
  end
end
