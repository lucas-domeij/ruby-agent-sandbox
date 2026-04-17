$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "agent_sandbox"

failures = []

def assert(label, cond, details = nil)
  if cond
    puts "  ok  #{label}"
  else
    puts "FAIL  #{label}  #{details}"
    yield if block_given?
  end
  cond
end

sandbox = AgentSandbox.new(backend: :docker, image: "ruby:3.3-slim")

begin
  sandbox.start
  puts "[exec]"
  r = sandbox.exec("echo hej")
  failures << "echo" unless assert("echo roundtrips", r.stdout.strip == "hej", r.stdout.inspect)
  failures << "success?" unless assert("success? true on 0", r.success?)

  puts "[non-zero exit]"
  r = sandbox.exec("false")
  failures << "non-zero" unless assert("status 1 captured", r.status == 1)

  puts "[files]"
  sandbox.write_file("/workspace/a/b/c.txt", "contents-123")
  read = sandbox.read_file("/workspace/a/b/c.txt")
  failures << "roundtrip" unless assert("file roundtrip", read == "contents-123", read.inspect)

  puts "[check: true raises]"
  begin
    sandbox.exec("exit 7", check: true)
    failures << "no raise"
  rescue AgentSandbox::ExecError => e
    assert("ExecError raised with status 7", e.status == 7, e.status.inspect)
  end

  puts "[isolation]"
  r = sandbox.exec("ls /Users 2>&1 || echo ABSENT")
  failures << "isolation" unless assert("host /Users not visible", r.stdout.include?("ABSENT"), r.stdout.inspect)
ensure
  sandbox.stop
end

if failures.empty?
  puts "\nall good"
  exit 0
else
  puts "\nfailures: #{failures.inspect}"
  exit 1
end
