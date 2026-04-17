require_relative "test_helper"

fails, assert = TestHelper.runner
backend = AgentSandbox::Backends::Docker.allocate # skip initialize, we only test parsing

# --- single-line IPv4 ---
m = backend.send(:pick_port_mapping, "127.0.0.1:49153\n")
assert.("ipv4 loopback parsed", m == { host: "127.0.0.1", port: 49153, bind: "127.0.0.1", family: :ipv4 }, m.inspect)

m = backend.send(:pick_port_mapping, "0.0.0.0:49153\n")
assert.("ipv4 any-addr rewritten to loopback", m && m[:host] == "127.0.0.1" && m[:bind] == "0.0.0.0", m.inspect)

# --- single-line IPv6 (bracketed) ---
m = backend.send(:pick_port_mapping, "[::]:49153\n")
assert.("ipv6 any-addr parsed", m && m[:family] == :ipv6 && m[:port] == 49153 && m[:host] == "::1", m.inspect)

m = backend.send(:pick_port_mapping, "[::1]:49153\n")
assert.("ipv6 loopback parsed", m && m[:family] == :ipv6 && m[:host] == "::1", m.inspect)

# --- old-docker IPv6 ":::port" form ---
m = backend.send(:pick_port_mapping, ":::49153\n")
assert.("old-style :::port parsed as ipv6", m && m[:family] == :ipv6 && m[:port] == 49153, m.inspect)

# --- dual-stack: two lines, IPv4 must win ---
m = backend.send(:pick_port_mapping, "[::]:49154\n0.0.0.0:49153\n")
assert.("dual-stack prefers ipv4 even when listed second", m && m[:family] == :ipv4 && m[:port] == 49153, m.inspect)

m = backend.send(:pick_port_mapping, "0.0.0.0:49153\n[::]:49154\n")
assert.("dual-stack ipv4-first still ipv4", m && m[:family] == :ipv4 && m[:port] == 49153, m.inspect)

# --- ipv6-only dual-stack: falls back cleanly ---
m = backend.send(:pick_port_mapping, "[::]:49154\n::1:49155\n")
assert.("ipv6-only output still resolves", m && m[:family] == :ipv6 && m[:port] == 49154, m.inspect)

# --- empty / garbage ---
assert.("empty output returns nil", backend.send(:pick_port_mapping, "") == nil)
assert.("garbage returns nil", backend.send(:pick_port_mapping, "not a port line\n") == nil)

# --- port_url brackets IPv6 ---
backend.instance_variable_set(:@port_map, { 8080 => { host: "::1", port: 49153, bind: "::", family: :ipv6 } })
assert.("port_url brackets ipv6", backend.port_url(8080) == "http://[::1]:49153", backend.port_url(8080))

backend.instance_variable_set(:@port_map, { 8080 => { host: "127.0.0.1", port: 49153, bind: "127.0.0.1", family: :ipv4 } })
assert.("port_url leaves ipv4 unbracketed", backend.port_url(8080) == "http://127.0.0.1:49153", backend.port_url(8080))

TestHelper.done(fails, label: "docker port parser")
