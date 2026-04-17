require "net/http"
require "uri"
require "json"
require "base64"
require "stringio"
require "securerandom"

module AgentSandbox
  module Backends
    # E2B cloud backend. Docs: https://e2b.dev/docs
    #
    # Uses E2B's control plane (api.e2b.app) for sandbox lifecycle, and the
    # per-sandbox `envd` daemon for file + process operations.
    #
    # Status of endpoints:
    #   create/kill  -> REST (well-documented)
    #   files        -> envd /files (documented in envd OpenAPI)
    #   exec         -> Connect-RPC over HTTP (best-effort; flip to the official
    #                   Ruby SDK when it exists)
    class E2B
      CONTROL_PLANE = "https://api.e2b.app".freeze

      def initialize(template: "base", api_key: ENV["E2B_API_KEY"], timeout: 3600, metadata: {})
        raise Error, "E2B_API_KEY not set" if api_key.nil? || api_key.empty?
        @api_key = api_key
        @template = template
        @timeout = timeout
        @metadata = metadata
        @sandbox_id = nil
        @envd_domain = nil
        @access_token = nil
      end

      def name = @sandbox_id

      def start
        body = { templateID: @template, timeout: @timeout, metadata: @metadata, secure: true }
        res = control_request(:post, "/sandboxes", body: body)
        @sandbox_id = res.fetch("sandboxID")
        @envd_domain = res["domain"] || "e2b.app"
        @access_token = res["envdAccessToken"]
        self
      end

      def stop
        return unless @sandbox_id
        control_request(:delete, "/sandboxes/#{@sandbox_id}", expect_json: false)
        @sandbox_id = nil
      end

      def write_file(path, content)
        uri = envd_uri("/files", user: "user", path: path)
        req = Net::HTTP::Post.new(uri)
        apply_envd_headers(req)
        req["Content-Type"] = "application/octet-stream"
        req.body = content
        response = http_for(uri).request(req)
        raise Error, "envd /files POST failed: #{response.code} #{response.body}" unless response.code.start_with?("2")
      end

      def read_file(path)
        uri = envd_uri("/files", user: "user", path: path)
        req = Net::HTTP::Get.new(uri)
        apply_envd_headers(req)
        response = http_for(uri).request(req)
        raise Error, "envd /files GET failed: #{response.code} #{response.body}" unless response.code.start_with?("2")
        response.body
      end

      # envd's process.Process/Start is a Connect-RPC server-streaming method.
      # Wire: framed body (5B header + JSON), response is a stream of frames
      # with start/data/end events. stdout/stderr come base64-encoded. The
      # final frame (flag 0x02) is the end-of-stream trailer: `{}` for success
      # or `{"error": {...}}` when envd failed.
      def exec(command)
        uri = envd_uri("/process.Process/Start")
        req = Net::HTTP::Post.new(uri)
        apply_envd_headers(req)
        req["Content-Type"] = "application/connect+json"
        req["Connect-Protocol-Version"] = "1"
        payload = JSON.generate(process: { cmd: "sh", args: ["-c", command] })
        req.body = pack_frame(payload)

        response = http_for(uri).request(req)
        raise Error, "envd exec #{response.code}: #{response.body&.force_encoding('BINARY')}" unless response.code.start_with?("2")

        consume_exec_stream(response.body)
      end

      # Reads the Connect-RPC server-streaming body into an ExecResult. Public
      # for tests — the network call is the only thing it doesn't cover.
      def consume_exec_stream(bytes)
        stdout = +""
        stderr = +""
        exit_status = nil
        saw_end = false
        saw_trailer = false

        parse_frames(bytes) do |kind, frame|
          if kind == :trailer
            saw_trailer = true
            if frame.is_a?(Hash) && frame["error"]
              raise Error, "envd stream error: #{frame["error"].inspect}"
            end
            next
          end
          event = frame["event"]
          next unless event
          if (data = event["data"])
            stdout << Base64.decode64(data["stdout"]) if data["stdout"]
            stderr << Base64.decode64(data["stderr"]) if data["stderr"]
          elsif (ending = event["end"])
            saw_end = true
            exit_status = parse_exit_status(ending["status"]) if ending["status"]
          end
        end

        raise Error, "envd exec stream ended without trailer" unless saw_trailer
        raise Error, "envd exec missing end event" unless saw_end
        raise Error, "envd end event missing exit status" if exit_status.nil?

        ExecResult.new(stdout: stdout, stderr: stderr, status: exit_status)
      end

      # E2B's envd delivers processes through a server-streaming Connect RPC,
      # so true fire-and-forget requires tagging the process + disconnecting
      # via the Connect/StreamInput pair. Advertise the gap via `supports?` so
      # `Sandbox#spawn` can reject before provisioning a remote sandbox.
      SUPPORTED = %i[exec write_file read_file port_url].freeze
      def supports?(capability) = SUPPORTED.include?(capability)

      # Backend-direct callers (bypassing Sandbox) still deserve a proper
      # AgentSandbox::Error — NOT NotImplementedError, which is a ScriptError
      # and slips past the library's rescue paths.
      def spawn(_command)
        raise UnsupportedOperation,
              "E2B backend does not support spawn yet (needs tagged Connect RPC). " \
              "Use exec for now, or run long-lived processes through the Docker backend."
      end

      def port_url(port)
        raise Error, "start sandbox first" unless @sandbox_id && @envd_domain
        "https://#{port}-#{@sandbox_id}.#{@envd_domain}"
      end

      private

      def control_request(method, path, body: nil, expect_json: true)
        uri = URI.join(CONTROL_PLANE, path)
        req =
          case method
          when :post then Net::HTTP::Post.new(uri)
          when :delete then Net::HTTP::Delete.new(uri)
          when :get then Net::HTTP::Get.new(uri)
          else raise ArgumentError, "method #{method}"
          end
        req["X-API-Key"] = @api_key
        if body
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(body)
        end
        response = http_for(uri).request(req)
        unless response.code.start_with?("2")
          raise Error, "E2B #{method.upcase} #{path} -> #{response.code}: #{response.body}"
        end
        return nil unless expect_json
        response.body.empty? ? {} : JSON.parse(response.body)
      end

      def envd_uri(path, **query)
        raise Error, "sandbox not started" unless @sandbox_id && @envd_domain
        uri = URI("https://49983-#{@sandbox_id}.#{@envd_domain}#{path}")
        uri.query = URI.encode_www_form(query) unless query.empty?
        uri
      end

      def apply_envd_headers(req)
        req["X-Access-Token"] = @access_token if @access_token
      end

      def http_for(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.read_timeout = 120
        http
      end

      def pack_frame(json_payload, flag: 0)
        [flag, json_payload.bytesize].pack("CN") + json_payload
      end

      # Yields [:message, hash] for normal frames and [:trailer, hash] for the
      # end-of-stream frame (Connect flag bit 0x02). Raises on truncation or
      # invalid JSON so failures can't be silently dropped.
      def parse_frames(bytes)
        return unless bytes
        io = StringIO.new(bytes.b)
        until io.eof?
          header = io.read(5)
          break if header.nil? || header.empty?
          raise Error, "envd stream truncated (partial header: #{header.bytesize}B)" if header.bytesize < 5
          flag, length = header.unpack("CN")
          payload = length.zero? ? "" : io.read(length).to_s
          raise Error, "envd stream truncated (wanted #{length}B, got #{payload.bytesize}B)" if payload.bytesize < length
          parsed = begin
            payload.empty? ? {} : JSON.parse(payload)
          rescue JSON::ParserError => e
            raise Error, "envd frame not JSON: #{e.message} (#{payload[0, 200].inspect})"
          end
          kind = (flag & 0x02 != 0) ? :trailer : :message
          yield kind, parsed
        end
      end

      # envd reports exit as a string like "exit status 0" or "signal: killed".
      def parse_exit_status(str)
        if (m = str.to_s.match(/exit status (\d+)/))
          m[1].to_i
        else
          1
        end
      end
    end
  end
end
