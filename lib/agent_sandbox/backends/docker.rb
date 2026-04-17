require "open3"
require "securerandom"
require "shellwords"

module AgentSandbox
  module Backends
    class Docker
      HARDENED_DEFAULTS = {
        user: "nobody",
        memory: "512m",
        pids_limit: 256,
        cpus: "1.0",
        # Agents often need internet (package installs, API calls). Pass
        # `network: :none` to block all egress.
        network: "bridge",
        read_only: true,
        drop_caps: true,
        no_new_privileges: true
      }.freeze

      attr_reader :name, :image, :ports, :port_map

      SUPPORTED = %i[exec spawn write_file read_file port_url].freeze
      def supports?(capability) = SUPPORTED.include?(capability)

      def initialize(
        image: "ruby:3.3-slim", ports: [], workdir: "/workspace", name: nil,
        hardened: true,
        user: nil, memory: nil, pids_limit: nil, cpus: nil,
        network: nil, read_only: nil, drop_caps: nil, no_new_privileges: nil,
        tmpfs_size: "256m",
        # Publish sandbox ports only on loopback by default. Pass "0.0.0.0"
        # to expose on all host interfaces (LAN-reachable) — opt-in only.
        port_bind: "127.0.0.1"
      )
        @image = image
        @ports = Array(ports)
        @workdir = workdir
        @name = name || "agent-sandbox-#{SecureRandom.hex(4)}"
        @port_map = {}
        @port_bind = port_bind
        @tmpfs_size = tmpfs_size

        defaults = hardened ? HARDENED_DEFAULTS : {}
        @user = user || defaults[:user]
        @memory = memory || defaults[:memory]
        @pids_limit = pids_limit || defaults[:pids_limit]
        @cpus = cpus || defaults[:cpus]
        @network = (network || defaults[:network])&.to_s
        @read_only = pick(read_only, defaults[:read_only])
        @drop_caps = pick(drop_caps, defaults[:drop_caps])
        @no_new_privileges = pick(no_new_privileges, defaults[:no_new_privileges])
      end

      def start
        cmd = ["docker", "run", "-d", "--name", @name, "-w", @workdir]
        cmd += ["--user", @user] if @user
        cmd += ["--memory", @memory] if @memory
        cmd += ["--pids-limit", @pids_limit.to_s] if @pids_limit
        cmd += ["--cpus", @cpus.to_s] if @cpus
        cmd += ["--cap-drop", "ALL"] if @drop_caps
        cmd += ["--security-opt", "no-new-privileges"] if @no_new_privileges
        cmd += ["--network", @network] if @network
        if @read_only
          cmd += ["--read-only"]
          cmd += ["--tmpfs", "#{@workdir}:rw,mode=1777,size=#{@tmpfs_size}"]
          cmd += ["--tmpfs", "/tmp:rw,mode=1777,size=64m"]
        end
        cmd += @ports.flat_map { |p| ["-p", "#{@port_bind}:0:#{p}"] }
        cmd += [@image, "sh", "-c", "sleep infinity"]
        run!(cmd)
        @started = true
        begin
          resolve_port_map if @ports.any?
        rescue
          # If port resolution fails, don't leave a dangling container.
          stop
          raise
        end
      end

      def exec(command)
        stdout, stderr, status = Open3.capture3("docker", "exec", @name, "sh", "-lc", command)
        ExecResult.new(stdout: stdout, stderr: stderr, status: status.exitstatus)
      end

      def spawn(command)
        system("docker", "exec", "-d", @name, "sh", "-lc", command, out: File::NULL, err: File::NULL) or raise Error, "spawn failed"
      end

      def write_file(path, content)
        Open3.popen3("docker", "exec", "-i", @name, "sh", "-c", "mkdir -p \"$(dirname #{Shellwords.escape(path)})\" && cat > #{Shellwords.escape(path)}") do |stdin, _out, _err, wait|
          stdin.write(content)
          stdin.close
          raise Error, "write_file failed" unless wait.value.success?
        end
      end

      def read_file(path)
        stdout, stderr, status = Open3.capture3("docker", "exec", @name, "cat", path)
        raise Error, "read_file failed: #{stderr.strip}" unless status.success?
        stdout
      end

      def port_url(port)
        raise Error, "sandbox not started — call start (or use `sandbox.open { ... }`) before port_url" unless @started
        unless @ports.include?(port)
          raise Error, "port #{port} was not declared at init (pass ports: [#{port}])"
        end
        binding = @port_map[port] or raise Error, "port #{port} not yet mapped by docker"
        host = binding[:family] == :ipv6 ? "[#{binding[:host]}]" : binding[:host]
        "http://#{host}:#{binding[:port]}"
      end

      def stop
        system("docker", "rm", "-f", @name, out: File::NULL, err: File::NULL)
      end

      private

      def pick(override, default)
        override.nil? ? default : override
      end

      def resolve_port_map
        @ports.each do |container_port|
          out, _err, status = Open3.capture3("docker", "port", @name, "#{container_port}/tcp")
          next unless status.success?
          mapping = pick_port_mapping(out)
          @port_map[container_port] = mapping if mapping
        end
      end

      # `docker port` may return multiple lines on dual-stack hosts, e.g.
      #   0.0.0.0:49153
      #   [::]:49153
      # Prefer an IPv4 binding so `port_url` hands back an address Ruby's
      # Net::HTTP / browsers can reach without fuss, and fall back to IPv6.
      def pick_port_mapping(out)
        candidates = out.lines.filter_map { |line| parse_port_line(line) }
        return nil if candidates.empty?
        candidates.find { |c| c[:family] == :ipv4 } || candidates.first
      end

      def parse_port_line(line)
        line = line.strip
        return nil if line.empty?
        # Split on the LAST colon so IPv6 hosts (which contain colons) survive.
        host, port = line.rpartition(":").then { |h, _, p| [h, p] }
        return nil unless port =~ /\A\d+\z/
        host = host.delete_prefix("[").delete_suffix("]") # strip [::] brackets
        family = host.include?(":") ? :ipv6 : :ipv4
        reachable =
          case host
          when "0.0.0.0" then "127.0.0.1"
          when "::", "" then "::1" # bare "" comes from `:::PORT` (old Docker IPv6 any)
          else host
          end
        { host: reachable, port: port.to_i, bind: host, family: family }
      end

      def run!(cmd)
        out, err, status = Open3.capture3(*cmd)
        raise Error, "#{cmd.first} failed: #{err.strip}#{out.strip}" unless status.success?
        out.strip
      end
    end
  end
end
