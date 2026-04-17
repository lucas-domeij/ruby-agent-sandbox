$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "agent_sandbox"

fails = []

assert = ->(label, cond, detail = nil) {
  if cond
    puts "  ok  #{label}"
  else
    puts "FAIL  #{label}  #{detail}"
    fails << label
  end
}

# Minimal Net::HTTPResponse stand-in — the classifier only looks at .code / .body.
FakeResp = Struct.new(:code, :body)

backend = AgentSandbox::Backends::E2B.allocate # bypass initialize

# --- missing api key --------------------------------------------------------
puts "[auth: missing api key]"
raised = nil
begin
  AgentSandbox::Backends::E2B.new(api_key: nil)
rescue AgentSandbox::AuthError => e
  raised = e
end
assert.("nil api key -> AuthError", raised.is_a?(AgentSandbox::AuthError))

raised = nil
begin
  AgentSandbox::Backends::E2B.new(api_key: "")
rescue AgentSandbox::AuthError => e
  raised = e
end
assert.("empty api key -> AuthError", raised.is_a?(AgentSandbox::AuthError))

# AuthError must inherit from Error so blanket rescue still catches it
assert.("AuthError < Error", AgentSandbox::AuthError.ancestors.include?(AgentSandbox::Error))

# --- status -> error mapping ------------------------------------------------
cases = {
  "401" => AgentSandbox::AuthError,
  "403" => AgentSandbox::AuthError,
  "404" => AgentSandbox::SandboxNotFound,
  "500" => AgentSandbox::ServerError,
  "502" => AgentSandbox::ServerError,
  "503" => AgentSandbox::ServerError,
  "504" => AgentSandbox::ServerError,
  "400" => AgentSandbox::HttpError,
  "422" => AgentSandbox::HttpError
}

puts "[status mapping]"
cases.each do |code, klass|
  raised = nil
  begin
    backend.send(:classify_response!, FakeResp.new(code, "{\"error\":\"x\"}"), what: "probe")
  rescue AgentSandbox::Error => e
    raised = e
  end
  assert.("HTTP #{code} -> #{klass.name.split('::').last}", raised.is_a?(klass), raised.inspect)
end

# 2xx must NOT raise
puts "[2xx does not raise]"
%w[200 201 204].each do |code|
  raised = nil
  begin
    backend.send(:classify_response!, FakeResp.new(code, ""), what: "probe")
  rescue => e
    raised = e
  end
  assert.("HTTP #{code} passes through", raised.nil?, raised&.inspect)
end

# HttpError preserves status + body for debugging
puts "[HttpError preserves status + body]"
raised = nil
begin
  backend.send(:classify_response!, FakeResp.new("422", "{\"detail\":\"bad request\"}"), what: "probe")
rescue AgentSandbox::HttpError => e
  raised = e
end
assert.("HttpError#status == 422", raised && raised.status == 422)
assert.("HttpError#body contains detail", raised && raised.body.include?("bad request"))

# --- retry/backoff math -----------------------------------------------------
puts "[backoff]"
backend.instance_variable_set(:@max_retries, 3)
assert.("backoff attempt 1", backend.send(:backoff_for, 1) == 0.5)
assert.("backoff attempt 2", backend.send(:backoff_for, 2) == 1.0)
assert.("backoff attempt 3", backend.send(:backoff_for, 3) == 2.0)

# --- retry loop actually retries on 503 -------------------------------------
puts "[perform_request retries transient 5xx]"
backend.instance_variable_set(:@open_timeout, 1)
backend.instance_variable_set(:@read_timeout, 1)

call_count = 0
fake_http = Object.new
responses = [FakeResp.new("503", ""), FakeResp.new("503", ""), FakeResp.new("200", "ok")]
fake_http.define_singleton_method(:request) do |_req|
  call_count += 1
  responses.shift
end
backend.define_singleton_method(:http_for) { |_uri| fake_http }
# Skip real sleeps so the test isn't slow.
backend.define_singleton_method(:backoff_for) { |_| 0 }

response = backend.send(:perform_request, URI("https://example.test/x"), Object.new, what: "probe")
assert.("retried through two 503s", call_count == 3, "calls=#{call_count}")
assert.("final response is 200", response.code == "200")

# After retries exhausted, returns the last response (classifier will reject it).
call_count = 0
persistently_503 = proc { FakeResp.new("503", "no") }
fake_http.define_singleton_method(:request) do |_req|
  call_count += 1
  persistently_503.call
end
response = backend.send(:perform_request, URI("https://example.test/x"), Object.new, what: "probe")
assert.("exhausted retries returns last response", response.code == "503" && call_count == 4, "calls=#{call_count}")

# --- timeout mapping --------------------------------------------------------
puts "[timeout -> TimeoutError]"
call_count = 0
fake_http.define_singleton_method(:request) do |_req|
  call_count += 1
  raise Net::ReadTimeout, "slow"
end
raised = nil
begin
  backend.send(:perform_request, URI("https://example.test/x"), Object.new, what: "probe")
rescue AgentSandbox::TimeoutError => e
  raised = e
end
assert.("Net::ReadTimeout -> TimeoutError", raised.is_a?(AgentSandbox::TimeoutError))
assert.("retried before raising", call_count == 4)

# --- connect error mapping --------------------------------------------------
puts "[connect failure -> ConnectError]"
call_count = 0
fake_http.define_singleton_method(:request) do |_req|
  call_count += 1
  raise Errno::ECONNREFUSED
end
raised = nil
begin
  backend.send(:perform_request, URI("https://example.test/x"), Object.new, what: "probe")
rescue AgentSandbox::ConnectError => e
  raised = e
end
assert.("Errno::ECONNREFUSED -> ConnectError", raised.is_a?(AgentSandbox::ConnectError))

if fails.empty?
  puts "\ne2b error mapping: all good"
  exit 0
else
  puts "\nFAIL: #{fails.inspect}"
  exit 1
end
