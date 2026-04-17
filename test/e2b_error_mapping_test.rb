require_relative "test_helper"
require "net/http"

fails, assert = TestHelper.runner

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
assert.("AuthError < Error", AgentSandbox::AuthError.ancestors.include?(AgentSandbox::Error))

# --- status -> error mapping ------------------------------------------------
cases = {
  401 => AgentSandbox::AuthError,
  403 => AgentSandbox::AuthError,
  404 => AgentSandbox::SandboxNotFound,
  500 => AgentSandbox::ServerError,
  502 => AgentSandbox::ServerError,
  503 => AgentSandbox::ServerError,
  504 => AgentSandbox::ServerError,
  400 => AgentSandbox::HttpError,
  422 => AgentSandbox::HttpError
}

puts "[status mapping]"
cases.each do |code, klass|
  raised = nil
  begin
    backend.send(:raise_for_status!, FakeResp.new(code.to_s, "{\"error\":\"x\"}"), code, what: "probe")
  rescue AgentSandbox::Error => e
    raised = e
  end
  assert.("HTTP #{code} -> #{klass.name.split('::').last}", raised.is_a?(klass), raised.inspect)
end

puts "[2xx does not raise]"
[200, 201, 204].each do |code|
  raised = nil
  begin
    backend.send(:raise_for_status!, FakeResp.new(code.to_s, ""), code, what: "probe")
  rescue => e
    raised = e
  end
  assert.("HTTP #{code} passes through", raised.nil?, raised&.inspect)
end

puts "[HttpError preserves status + body]"
raised = nil
begin
  backend.send(:raise_for_status!, FakeResp.new("422", "{\"detail\":\"bad request\"}"), 422, what: "probe")
rescue AgentSandbox::HttpError => e
  raised = e
end
assert.("HttpError#status == 422", raised && raised.status == 422)
assert.("HttpError#body contains detail", raised && raised.body.include?("bad request"))

# --- backoff math -----------------------------------------------------------
puts "[backoff]"
# Backoff now includes jitter; check the baseline floor + ceiling rather than exact value.
backend.instance_variable_set(:@max_retries, 3)
10.times do |_i|
  b1 = backend.send(:backoff_for, 1)
  b2 = backend.send(:backoff_for, 2)
  b3 = backend.send(:backoff_for, 3)
  unless (0.5..0.625).cover?(b1) && (1.0..1.25).cover?(b2) && (2.0..2.5).cover?(b3)
    fails << "backoff out of range: b1=#{b1} b2=#{b2} b3=#{b3}"
    break
  end
end
assert.("backoff within jittered range", fails.none? { |f| f.to_s.start_with?("backoff out") })

# --- retry loop retries idempotent requests ---------------------------------
puts "[perform_request retries transient 5xx on GET]"
backend.instance_variable_set(:@open_timeout, 1)
backend.instance_variable_set(:@read_timeout, 1)
backend.define_singleton_method(:backoff_for) { |_| 0 } # skip real sleeps

call_count = 0
fake_http = Object.new
responses = [FakeResp.new("503", ""), FakeResp.new("503", ""), FakeResp.new("200", "ok")]
fake_http.define_singleton_method(:request) do |_req|
  call_count += 1
  responses.shift
end
backend.define_singleton_method(:http_for) { |_uri| fake_http }

uri = URI("https://example.test/x")
get_req = Net::HTTP::Get.new(uri)
response = backend.send(:perform_request, uri, get_req, what: "probe")
assert.("GET retried through two 503s", call_count == 3, "calls=#{call_count}")
assert.("final response is 200", response.code == "200")

# Retries exhausted on persistent GET 503 -> ServerError from raise_for_status.
call_count = 0
fake_http.define_singleton_method(:request) { |_req| call_count += 1; FakeResp.new("503", "no") }
raised = nil
begin
  backend.send(:perform_request, uri, Net::HTTP::Get.new(uri), what: "probe")
rescue AgentSandbox::ServerError => e
  raised = e
end
assert.("persistent GET 503 -> ServerError", raised.is_a?(AgentSandbox::ServerError))
assert.("exhausted retries = 4 total attempts", call_count == 4, "calls=#{call_count}")

# --- POST must NOT retry (non-idempotent) -----------------------------------
puts "[POST does not retry — sandbox create must not duplicate]"
call_count = 0
fake_http.define_singleton_method(:request) { |_req| call_count += 1; FakeResp.new("503", "transient") }
raised = nil
begin
  backend.send(:perform_request, uri, Net::HTTP::Post.new(uri), what: "probe")
rescue AgentSandbox::ServerError => e
  raised = e
end
assert.("POST 503 raises ServerError", raised.is_a?(AgentSandbox::ServerError))
assert.("POST attempted exactly once", call_count == 1, "calls=#{call_count}")

# --- timeout mapping --------------------------------------------------------
puts "[timeout -> TimeoutError]"
call_count = 0
fake_http.define_singleton_method(:request) { |_req| call_count += 1; raise Net::ReadTimeout, "slow" }
raised = nil
begin
  backend.send(:perform_request, uri, Net::HTTP::Get.new(uri), what: "probe")
rescue AgentSandbox::TimeoutError => e
  raised = e
end
assert.("Net::ReadTimeout -> TimeoutError", raised.is_a?(AgentSandbox::TimeoutError))
assert.("retried 4 times before raising", call_count == 4)

# POST timeout: no retry
call_count = 0
fake_http.define_singleton_method(:request) { |_req| call_count += 1; raise Net::ReadTimeout, "slow" }
raised = nil
begin
  backend.send(:perform_request, uri, Net::HTTP::Post.new(uri), what: "probe")
rescue AgentSandbox::TimeoutError => e
  raised = e
end
assert.("POST timeout -> TimeoutError", raised.is_a?(AgentSandbox::TimeoutError))
assert.("POST timeout not retried", call_count == 1)

# --- connect error mapping --------------------------------------------------
puts "[connect failure -> ConnectError]"
call_count = 0
fake_http.define_singleton_method(:request) { |_req| call_count += 1; raise Errno::ECONNREFUSED }
raised = nil
begin
  backend.send(:perform_request, uri, Net::HTTP::Get.new(uri), what: "probe")
rescue AgentSandbox::ConnectError => e
  raised = e
end
assert.("Errno::ECONNREFUSED -> ConnectError", raised.is_a?(AgentSandbox::ConnectError))

# --- SSL cert failure: never retried ----------------------------------------
puts "[SSL cert verification failure is terminal, not retried]"
call_count = 0
fake_http.define_singleton_method(:request) do |_req|
  call_count += 1
  raise OpenSSL::SSL::SSLError, "SSL_connect returned=1 errno=0 state=error: certificate verify failed"
end
raised = nil
begin
  backend.send(:perform_request, uri, Net::HTTP::Get.new(uri), what: "probe")
rescue AgentSandbox::ConnectError => e
  raised = e
end
assert.("cert verify failure -> ConnectError", raised.is_a?(AgentSandbox::ConnectError))
assert.("cert verify failure attempted exactly once", call_count == 1, "calls=#{call_count}")

# --- orphan prevention: start must refuse when prior sandbox_id still set ---
puts "[E2B#start refuses to provision while a previous sandbox_id is unresolved]"
orphan_backend = AgentSandbox::Backends::E2B.allocate
orphan_backend.instance_variable_set(:@sandbox_id, "leftover-from-failed-stop")
raised = nil
begin
  orphan_backend.start
rescue AgentSandbox::Error => e
  raised = e.message
end
assert.(
  "start refuses with stale sandbox_id",
  raised && raised.include?("leftover-from-failed-stop") && raised.include?("still tracked"),
  raised.inspect
)

TestHelper.done(fails, label: "e2b error mapping")
