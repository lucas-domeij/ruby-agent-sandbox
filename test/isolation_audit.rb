$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "agent_sandbox"

sandbox = AgentSandbox.new(backend: :docker, image: "ruby:3.3-slim")

def check(label, result)
  puts "== #{label} =="
  puts "  status=#{result.status}"
  out = (result.stdout + result.stderr).strip
  puts out.lines.first(6).map { "  #{_1.chomp}" }.join("\n")
  puts
end

sandbox.with do |s|
  check "whoami",            s.exec("whoami && id")
  check "host filesystem",   s.exec("ls /Users 2>&1; ls /host 2>&1; ls / | head -20")
  check "docker socket",     s.exec("ls -la /var/run/docker.sock 2>&1")
  check "outbound internet", s.exec("getent hosts example.com || echo dns-fail; curl -s -o /dev/null -w 'http=%{http_code} time=%{time_total}s\\n' https://example.com --max-time 5")
  check "reach host LAN",    s.exec("ip route 2>&1; (echo > /dev/tcp/host.docker.internal/22) 2>&1 && echo host:22-OPEN || echo host:22-no")
  check "capabilities",      s.exec("grep CapEff /proc/self/status; apt list --installed 2>/dev/null | grep -i capability || true")
  check "memory limit",      s.exec("cat /sys/fs/cgroup/memory.max 2>/dev/null; free -h 2>&1 | head -3")
  check "pids limit",        s.exec("cat /sys/fs/cgroup/pids.max 2>/dev/null")
  check "can mount / sudo",  s.exec("mount -t tmpfs none /mnt 2>&1; which sudo; apt install -y strace 2>&1 | tail -2")
end
