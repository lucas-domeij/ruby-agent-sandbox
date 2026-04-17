require_relative "test_helper"
require "base64"
require "json"

fails, assert = TestHelper.runner

def pack(json, flag: 0)
  payload = JSON.generate(json)
  [flag, payload.bytesize].pack("CN") + payload
end

# Real envd-style base64 for stdout/stderr bodies
def b64(str) = Base64.strict_encode64(str)

backend = AgentSandbox::Backends::E2B.allocate # skip initialize (no api key needed)

puts "[happy path]"
body =
  pack({ event: { start: { pid: 1 } } }) +
  pack({ event: { data: { stdout: b64("hej\n") } } }) +
  pack({ event: { data: { stderr: b64("warning\n") } } }) +
  pack({ event: { end: { exited: true, status: "exit status 0" } } }) +
  pack({}, flag: 0x02)
r = backend.consume_exec_stream(body)
assert.("stdout captured", r.stdout == "hej\n", r.stdout.inspect)
assert.("stderr captured", r.stderr == "warning\n", r.stderr.inspect)
assert.("exit status parsed", r.status == 0)

puts "[non-zero exit]"
body =
  pack({ event: { end: { exited: true, status: "exit status 7" } } }) +
  pack({}, flag: 0x02)
r = backend.consume_exec_stream(body)
assert.("non-zero status", r.status == 7)

puts "[error trailer raises]"
body =
  pack({ event: { start: { pid: 2 } } }) +
  pack({ error: { code: "internal", message: "envd exploded" } }, flag: 0x02)
raised = nil
begin
  backend.consume_exec_stream(body)
rescue AgentSandbox::Error => e
  raised = e.message
end
assert.("error trailer surfaces", raised && raised.include?("envd exploded"), raised.inspect)

puts "[missing trailer raises]"
body = pack({ event: { end: { exited: true, status: "exit status 0" } } })
raised = nil
begin
  backend.consume_exec_stream(body)
rescue AgentSandbox::Error => e
  raised = e.message
end
assert.("no trailer → raise", raised&.include?("without trailer"), raised.inspect)

puts "[missing end event raises]"
body =
  pack({ event: { data: { stdout: b64("partial") } } }) +
  pack({}, flag: 0x02)
raised = nil
begin
  backend.consume_exec_stream(body)
rescue AgentSandbox::Error => e
  raised = e.message
end
assert.("no end event → raise", raised&.include?("missing end event"), raised.inspect)

puts "[truncated body raises]"
body = pack({ event: { data: { stdout: b64("x") } } })[0, 7] # chop mid-payload
raised = nil
begin
  backend.consume_exec_stream(body)
rescue AgentSandbox::Error => e
  raised = e.message
end
assert.("truncated body → raise", raised&.include?("truncated"), raised.inspect)

puts "[spawn unsupported on E2B]"
assert.("supports? reports no spawn", backend.supports?(:spawn) == false)
assert.("supports? reports exec", backend.supports?(:exec))

raised = nil
begin
  backend.spawn("whatever")
rescue AgentSandbox::UnsupportedOperation => e
  raised = e.message
end
assert.(
  "backend spawn raises UnsupportedOperation (catchable via AgentSandbox::Error)",
  raised&.include?("does not support spawn"),
  raised.inspect
)

# Sandbox#spawn must reject E2B BEFORE touching the network — otherwise we'd
# provision a remote sandbox only to fail on dispatch. We stub start/stop to
# prove the capability gate trips first.
sandbox = AgentSandbox::Sandbox.new(backend)
started = false
backend.define_singleton_method(:start) { started = true; self }
raised = nil
begin
  sandbox.spawn("anything")
rescue AgentSandbox::UnsupportedOperation => e
  raised = e.message
end
assert.("Sandbox#spawn rejects unsupported backend", raised && !raised.empty?, raised.inspect)
assert.("Sandbox#spawn did not provision before rejecting", started == false)

TestHelper.done(fails, label: "e2b frames")
