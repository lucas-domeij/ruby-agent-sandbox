$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "agent_sandbox"

sandbox = AgentSandbox.new(backend: :docker, image: "ruby:3.3-slim")

sandbox.with do |s|
  puts "-- whoami --"
  puts s.exec("whoami").stdout

  puts "-- write + read --"
  s.write_file("/workspace/hello.rb", %(puts "hello from sandbox, 2 + 2 = #{2 + 2}"\n))
  puts s.read_file("/workspace/hello.rb")

  puts "-- run it --"
  puts s.exec("ruby /workspace/hello.rb").stdout

  puts "-- attempt something naughty --"
  r = s.exec("cat /etc/shadow")
  puts "status=#{r.status}"
  puts "stderr=#{r.stderr.strip}"
end
