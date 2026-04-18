require_relative "test_helper"

fails, assert = TestHelper.runner

# Build a Docker backend without running `docker run`, then stub just the
# `system` call (the one `stop` uses) so the real Docker#stop logic runs.
def fresh_backend(ports: [8080])
  b = AgentSandbox::Backends::Docker.allocate
  b.instance_variable_set(:@name, "agent-sandbox-test")
  b.instance_variable_set(:@ports, ports)
  b.instance_variable_set(:@port_map, {})
  b.instance_variable_set(:@started, false)
  b.instance_variable_set(:@system_result, true)
  def b.system(*_args, **_opts); @system_result; end
  b
end

puts "[port_url fails after stop, even though mapping was cached]"
backend = fresh_backend
backend.instance_variable_set(:@started, true)
backend.instance_variable_set(:@port_map, { 8080 => { host: "127.0.0.1", port: 49153, bind: "127.0.0.1", family: :ipv4 } })
assert.("port_url works while started", backend.port_url(8080) == "http://127.0.0.1:49153")

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
backend = fresh_backend
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

puts "[Sandbox#stop clears wrapper state even when backend.stop raises]"
backend = fresh_backend
backend.instance_variable_set(:@started, true)
backend.instance_variable_set(:@system_result, false) # docker rm -f will fail
sandbox = AgentSandbox::Sandbox.new(backend)
sandbox.instance_variable_set(:@started, true)
raised = nil
begin
  sandbox.stop
rescue AgentSandbox::Error => e
  raised = e
end
assert.("Sandbox#stop re-raises backend cleanup failure", raised.is_a?(AgentSandbox::Error))
assert.("Sandbox wrapper @started cleared despite backend failure",
        sandbox.instance_variable_get(:@started) == false)

# Follow-up: after a rescued stop error, #exec must NOT skip restart.
# We stub start so we can observe whether the wrapper re-runs it.
start_calls = 0
backend.define_singleton_method(:start) { start_calls += 1; @started = true }
backend.define_singleton_method(:exec) { |_| AgentSandbox::ExecResult.new(stdout: "", stderr: "", status: 0) }
sandbox.exec("true")
assert.("after failed stop, next op triggers fresh start", start_calls == 1, "calls=#{start_calls}")

puts "[Sandbox#open: block error preserved when cleanup also fails]"
backend = fresh_backend
# start/stop both stubbed at the backend level so we can trigger them.
backend.define_singleton_method(:start) { @started = true }
backend.define_singleton_method(:stop) { raise AgentSandbox::Error, "rm failed too" }
sandbox = AgentSandbox::Sandbox.new(backend)
raised = nil
begin
  sandbox.open { |_| raise ArgumentError, "original block boom" }
rescue => e
  raised = e
end
assert.("combined error keeps original class", raised.is_a?(ArgumentError), raised.inspect)
assert.("combined error keeps original message", raised.message == "original block boom", raised.message.inspect)
assert.(
  "combined error backtrace points at original raise site",
  raised.backtrace && raised.backtrace.any? { |l| l.include?("docker_lifecycle_test.rb") },
  raised.backtrace&.first
)
assert.(
  "cleanup failure reachable via #cause",
  raised.cause.is_a?(AgentSandbox::Error) && raised.cause.message.include?("rm failed too"),
  raised.cause.inspect
)

puts "[Sandbox#open: kwarg-initialized library exceptions survive dual-failure]"
exec_orig = AgentSandbox::ExecError.new(status: 7, stdout: "out", stderr: "err")
http_orig = AgentSandbox::HttpError.new(status: 502, body: "bad gateway")

[["ExecError", exec_orig], ["HttpError", http_orig]].each do |label, original|
  backend2 = fresh_backend
  backend2.define_singleton_method(:start) { @started = true }
  backend2.define_singleton_method(:stop) { raise AgentSandbox::Error, "stop boom" }
  sandbox2 = AgentSandbox::Sandbox.new(backend2)
  raised = nil
  begin
    sandbox2.open { |_| raise original }
  rescue => e
    raised = e
  end
  assert.("#{label}: class preserved", raised.class == original.class, raised.class.to_s)
  assert.("#{label}: message preserved", raised.message == original.message, raised.message)
  assert.("#{label}: cleanup attached as cause",
          raised.cause.is_a?(AgentSandbox::Error) && raised.cause.message.include?("stop boom"),
          raised.cause.inspect)
end

# Spot-check: ExecError-specific ivars survive the clone (status, stderr, stdout)
backend2 = fresh_backend
backend2.define_singleton_method(:start) { @started = true }
backend2.define_singleton_method(:stop) { raise AgentSandbox::Error, "stop boom" }
sandbox2 = AgentSandbox::Sandbox.new(backend2)
raised = nil
begin
  sandbox2.open { |_| raise AgentSandbox::ExecError.new(status: 42, stdout: "S", stderr: "E") }
rescue AgentSandbox::ExecError => e
  raised = e
end
assert.("ExecError#status preserved through clone", raised.status == 42, raised.status.inspect)
assert.("ExecError#stderr preserved through clone", raised.stderr == "E", raised.stderr.inspect)
assert.("ExecError#stdout preserved through clone", raised.stdout == "S", raised.stdout.inspect)

puts "[Sandbox#open: clean cleanup re-raises original block error untouched]"
backend = fresh_backend
backend.define_singleton_method(:start) { @started = true }
stop_called = false
backend.define_singleton_method(:stop) { stop_called = true; @started = false }
sandbox = AgentSandbox::Sandbox.new(backend)
raised = nil
begin
  sandbox.open { |_| raise ArgumentError, "picky" }
rescue ArgumentError => e
  raised = e.message
end
assert.("original block error preserved", raised == "picky", raised.inspect)
assert.("stop still ran", stop_called)

puts "[Sandbox#open runs stop on non-exception exits (return/break/throw)]"
def run_with_return(sandbox)
  sandbox.open { |_| return :early }
end

backend = fresh_backend
events = []
backend.define_singleton_method(:start) { events << :start; @started = true }
backend.define_singleton_method(:stop)  { events << :stop;  @started = false }
sandbox = AgentSandbox::Sandbox.new(backend)
result = run_with_return(sandbox)
assert.("return from block still unwinds",  result == :early)
assert.("stop ran on return-from-block",    events == [:start, :stop], events.inspect)

events.clear
backend2 = fresh_backend
backend2.define_singleton_method(:start) { events << :start; @started = true }
backend2.define_singleton_method(:stop)  { events << :stop;  @started = false }
sandbox2 = AgentSandbox::Sandbox.new(backend2)
catch(:bail) { sandbox2.open { |_| throw :bail } }
assert.("stop ran on throw-from-block", events == [:start, :stop], events.inspect)

events.clear
backend3 = fresh_backend
backend3.define_singleton_method(:start) { events << :start; @started = true }
backend3.define_singleton_method(:stop)  { events << :stop;  @started = false }
sandbox3 = AgentSandbox::Sandbox.new(backend3)
loop do
  sandbox3.open { |_| break }
  break
end
assert.("stop ran on break-from-block", events == [:start, :stop], events.inspect)

puts "[Sandbox#open and #with happy-path parity]"
backend = fresh_backend
events = []
backend.define_singleton_method(:start) { events << :start; @started = true }
backend.define_singleton_method(:stop)  { events << :stop;  @started = false }
sandbox = AgentSandbox::Sandbox.new(backend)
sandbox.open { |_| events << :body }
assert.("open -> start, body, stop", events == [:start, :body, :stop], events.inspect)

events.clear
sandbox2 = AgentSandbox::Sandbox.new(fresh_backend.tap { |b|
  b.define_singleton_method(:start) { events << :start; @started = true }
  b.define_singleton_method(:stop)  { events << :stop;  @started = false }
})
sandbox2.with { |_| events << :body }
assert.("#with alias drives the same order", events == [:start, :body, :stop], events.inspect)

puts "[start rollback: resolve_port_map failure triggers stop]"
backend = fresh_backend
backend.define_singleton_method(:run!) { |_cmd| "container-id" }
backend.define_singleton_method(:resolve_port_map) { raise AgentSandbox::Error, "port resolve exploded" }
# Leave real Docker#stop in place — it will use the stubbed `system`.
backend.instance_variable_set(:@system_result, true)
raised = nil
begin
  backend.start
rescue AgentSandbox::Error => e
  raised = e.message
end
assert.("start re-raises original error on rollback", raised && raised.include?("port resolve exploded"), raised.inspect)
assert.("started cleared after rollback", backend.instance_variable_get(:@started) == false)

puts "[start rollback: cleanup failure surfaces both errors]"
backend = fresh_backend
backend.define_singleton_method(:run!) { |_cmd| "container-id" }
backend.define_singleton_method(:resolve_port_map) { raise AgentSandbox::Error, "port resolve exploded" }
backend.instance_variable_set(:@system_result, false) # real Docker#stop will raise
raised = nil
begin
  backend.start
rescue AgentSandbox::Error => e
  raised = e.message
end
assert.(
  "rollback failure surfaces both original + cleanup",
  raised && raised.include?("port resolve exploded") && raised.include?("cleanup failed"),
  raised.inspect
)

TestHelper.done(fails, label: "docker lifecycle")
