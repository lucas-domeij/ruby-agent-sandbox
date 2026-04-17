$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "agent_sandbox"
require "open3"

fails = []

# Default: 127.0.0.1
sandbox = AgentSandbox.new(backend: :docker, image: "ruby:3.3-slim", ports: [8080])
begin
  sandbox.start
  backend = sandbox.instance_variable_get(:@backend)
  mapping = backend.port_map[8080]
  unless mapping && mapping[:bind] == "127.0.0.1"
    fails << "default bind != 127.0.0.1 (got #{mapping.inspect})"
  end
  url = sandbox.port_url(8080)
  unless url.start_with?("http://127.0.0.1:")
    fails << "port_url not loopback: #{url}"
  end

  # Verify via docker port output that the binding is actually loopback
  out, _err, _status = Open3.capture3("docker", "port", backend.name, "8080/tcp")
  fails << "docker port claim not loopback: #{out}" unless out.start_with?("127.0.0.1:")

  puts "default: port_url=#{url}, docker port=#{out.strip}"
ensure
  sandbox.stop
end

# Opt-in: 0.0.0.0 still supported
sandbox = AgentSandbox.new(backend: :docker, image: "ruby:3.3-slim", ports: [8080], port_bind: "0.0.0.0")
begin
  sandbox.start
  backend = sandbox.instance_variable_get(:@backend)
  mapping = backend.port_map[8080]
  unless mapping && mapping[:bind] == "0.0.0.0"
    fails << "opt-in 0.0.0.0 not honored (got #{mapping.inspect})"
  end
  puts "opt-in: bind=#{mapping && mapping[:bind]} port_url=#{sandbox.port_url(8080)}"
ensure
  sandbox.stop
end

if fails.empty?
  puts "\nport bind regression: all good"
  exit 0
else
  puts "\nFAIL: #{fails.inspect}"
  exit 1
end
