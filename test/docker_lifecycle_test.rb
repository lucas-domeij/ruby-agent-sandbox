require_relative "test_helper"

fails, assert = TestHelper.runner

# We stub out the `docker` CLI so these tests run without a daemon.
backend = AgentSandbox::Backends::Docker.allocate
backend.instance_variable_set(:@name, "agent-sandbox-test")
backend.instance_variable_set(:@ports, [8080])
backend.instance_variable_set(:@port_map, {})
backend.instance_variable_set(:@started, false)

# Override `stop` to the real implementation but replace the system call so
# we don't actually need Docker. We still want the state-clearing behavior.
def backend.system(*_args, **_opts); @system_result; end

puts "[port_url fails after stop, even though mapping was cached]"
backend.instance_variable_set(:@started, true)
backend.instance_variable_set(:@port_map, { 8080 => { host: "127.0.0.1", port: 49153, bind: "127.0.0.1", family: :ipv4 } })
assert.("port_url works while started", backend.port_url(8080) == "http://127.0.0.1:49153")

backend.instance_variable_set(:@system_result, true)
backend.stop

raised = nil
begin
  backend.port_url(8080)
rescue AgentSandbox::Error => e
  raised = e.message
end
assert.("port_url raises after stop", raised && raised.include?("not started"), raised.inspect)
assert.("port_map cleared after stop", backend.instance_variable_get(:@port_map) == {})
assert.("started flag cleared after stop", backend.instance_variable_get(:@started) == false)

puts "[stop raises when docker rm -f fails, but still clears state]"
backend.instance_variable_set(:@started, true)
backend.instance_variable_set(:@port_map, { 8080 => { host: "127.0.0.1", port: 49153, bind: "127.0.0.1", family: :ipv4 } })
backend.instance_variable_set(:@system_result, false)
raised = nil
begin
  backend.stop
rescue AgentSandbox::Error => e
  raised = e.message
end
assert.("stop raises on rm failure", raised && raised.include?("docker rm"), raised.inspect)
assert.("state cleared even when rm fails", backend.instance_variable_get(:@started) == false)
assert.("port_map cleared even when rm fails", backend.instance_variable_get(:@port_map) == {})

puts "[Sandbox#open and #with exercise the same lifecycle]"
# Fake backend that records calls and produces a mapping during start.
class FakeBackend
  attr_reader :events, :port_map
  def initialize
    @events = []
    @started = false
    @port_map = {}
  end
  def start
    @events << :start
    @started = true
    @port_map[8080] = { host: "127.0.0.1", port: 40001, bind: "127.0.0.1", family: :ipv4 }
  end
  def stop
    @events << :stop
    @started = false
    @port_map = {}
  end
  def port_url(port)
    raise AgentSandbox::Error, "sandbox not started — call start (or use `sandbox.open { ... }`) before port_url" unless @started
    m = @port_map[port] or raise AgentSandbox::Error, "port #{port} not mapped"
    "http://#{m[:host]}:#{m[:port]}"
  end
  def supports?(_) = true
end

fb = FakeBackend.new
sandbox = AgentSandbox::Sandbox.new(fb)
url = nil
sandbox.open { |s| url = s.port_url(8080) }
assert.("open yielded a live URL", url == "http://127.0.0.1:40001", url.inspect)
assert.("open ran start then stop", fb.events == [:start, :stop], fb.events.inspect)

raised = nil
begin
  sandbox.port_url(8080)
rescue AgentSandbox::Error => e
  raised = e.message
end
assert.("port_url raises after block exits", raised && raised.include?("not started"), raised.inspect)

fb2 = FakeBackend.new
sandbox2 = AgentSandbox::Sandbox.new(fb2)
sandbox2.with { |_| } # alias still works
assert.("#with alias drives the same lifecycle", fb2.events == [:start, :stop], fb2.events.inspect)

puts "[start rollback: resolve_port_map failure triggers stop]"
backend2 = AgentSandbox::Backends::Docker.allocate
backend2.instance_variable_set(:@name, "agent-sandbox-rollback")
backend2.instance_variable_set(:@ports, [8080])
backend2.instance_variable_set(:@port_map, {})
backend2.instance_variable_set(:@started, false)

# Stub run! so `docker run` appears to succeed; stub resolve_port_map to fail;
# capture whether `stop` was called to roll back.
backend2.define_singleton_method(:run!) { |_cmd| "container-id" }
backend2.define_singleton_method(:resolve_port_map) { raise AgentSandbox::Error, "port resolve exploded" }
stop_called = false
backend2.define_singleton_method(:stop) do
  stop_called = true
  @started = false
  @port_map = {}
end

raised = nil
begin
  backend2.start
rescue AgentSandbox::Error => e
  raised = e.message
end
assert.("start re-raises original error on rollback", raised && raised.include?("port resolve exploded"), raised.inspect)
assert.("stop was called during rollback", stop_called)
assert.("started cleared after rollback", backend2.instance_variable_get(:@started) == false)

puts "[start rollback: cleanup failure surfaces both errors]"
backend3 = AgentSandbox::Backends::Docker.allocate
backend3.instance_variable_set(:@name, "agent-sandbox-rollback2")
backend3.instance_variable_set(:@ports, [8080])
backend3.instance_variable_set(:@port_map, {})
backend3.instance_variable_set(:@started, false)
backend3.define_singleton_method(:run!) { |_cmd| "container-id" }
backend3.define_singleton_method(:resolve_port_map) { raise AgentSandbox::Error, "port resolve exploded" }
backend3.define_singleton_method(:stop) { raise AgentSandbox::Error, "docker rm -f failed too" }

raised = nil
begin
  backend3.start
rescue AgentSandbox::Error => e
  raised = e.message
end
assert.(
  "rollback failure surfaces both original + cleanup",
  raised && raised.include?("port resolve exploded") && raised.include?("cleanup failed"),
  raised.inspect
)

TestHelper.done(fails, label: "docker lifecycle")
