$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "agent_sandbox"
require "agent_sandbox/ruby_llm_tools"

# Verifies the RubyLLM tool wrappers call through to the sandbox correctly,
# without involving a real LLM.
sandbox = AgentSandbox.new(backend: :docker, image: "ruby:3.3-slim")

fails = []

begin
  sandbox.start
  tools = AgentSandbox::RubyLLMTools.build(sandbox)
  exec, write_file, read_file, _port_url = tools

  r = exec.execute(command: "echo from-tool")
  fails << "exec stdout" unless r[:stdout].strip == "from-tool"
  fails << "exec status" unless r[:status] == 0

  write_file.execute(path: "/workspace/tooltest.txt", content: "hello-tool")
  read = read_file.execute(path: "/workspace/tooltest.txt")
  fails << "roundtrip via tool" unless read[:content] == "hello-tool"

  missing = read_file.execute(path: "/workspace/does-not-exist")
  fails << "missing file should return error" unless missing[:error]
ensure
  sandbox.stop
end

if fails.empty?
  puts "ruby_llm tool wrappers: all good"
  exit 0
else
  puts "FAIL: #{fails.inspect}"
  exit 1
end
