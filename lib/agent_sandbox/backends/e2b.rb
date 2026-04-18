require "net/http"
require "openssl"
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

      DEFAULT_OPEN_TIMEOUT = 10
      DEFAULT_READ_TIMEOUT = 120
      # Extra attempts beyond the initial one. max_retries=3 => up to 4 total
      # HTTP round trips on persistent failure.
      DEFAULT_MAX_RETRIES = 3
      RETRY_BACKOFF_BASE = 0.5
      RETRIABLE_STATUSES = [502, 503, 504].freeze
      IDEMPOTENT_METHODS = %w[GET HEAD DELETE].freeze

      def initialize(template: "base", api_key: ENV["E2B_API_KEY"], timeout: 3600,
                     metadata: {}, open_timeout: DEFAULT_OPEN_TIMEOUT,
                     read_timeout: DEFAULT_READ_TIMEOUT, max_retries: DEFAULT_MAX_RETRIES)
        raise AuthError, "E2B_API_KEY not set" if api_key.nil? || api_key.empty?
        @api_key = api_key
        @template = template
        @timeout = timeout
        @metadata = metadata
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @max_retries = max_retries
        @sandbox_id = nil
        @envd_domain = nil
        @access_token = nil
      end

      def name = @sandbox_id

      def start
        if @sandbox_id
          # Refuse to provision a second sandbox while a previous one is
          # still unresolved — otherwise a failed stop + restart orphans the
          # first sandbox (and keeps billing it) while losing its handle.
          raise Error, "previous sandbox #{@sandbox_id} still tracked; call stop again or abandon this backend instance"
        end
        body = { templateID: @template, timeout: @timeout, metadata: @metadata, secure: true }
        res = control_request(:post, "/sandboxes", body: body)
        @sandbox_id = res.fetch("sandboxID")
        @envd_domain = res["domain"] || "e2b.app"
        @access_token = res["envdAccessToken"]
        self
      end

      # E2B's control-plane 404 responses for deleted/missing sandboxes
      # return JSON with sandbox-specific identifying content. Substrings
      # we accept inside provider-structured fields only — not anywhere in
      # an arbitrary response body — so a bare 404 from path drift, a
      # proxy, or an intermediate error page cannot fool stop into
      # clearing the handle to a still-running, still-billing sandbox.
      SANDBOX_NOT_FOUND_MARKERS = [
        "sandbox not found",
        "sandbox does not exist",
        "sandbox was not found",
        "no such sandbox"
      ].freeze

      def stop
        return unless @sandbox_id
        begin
          control_request(:delete, "/sandboxes/#{@sandbox_id}", expect_json: false)
        rescue SandboxNotFound => e
          raise unless sandbox_not_found_response?(e)
        end
        # Only clear @sandbox_id once we've confirmed the sandbox is gone
        # (2xx or validated 404). Other failures keep it set so start()
        # can refuse rather than orphan the remote sandbox.
        @sandbox_id = nil
      end

      # Structured 404 check: require a JSON body whose provider fields
      # positively identify "this sandbox is gone". We only trust the
      # `code`, `type`, `error`, or `message` fields, not substring
      # matches against the raw body (which would let an HTML proxy page
      # or CDN error containing the word "sandbox" fool us).
      def sandbox_not_found_response?(error)
        return false unless error.status == 404
        body = error.body.to_s
        return false if body.empty?
        parsed = begin
          JSON.parse(body)
        rescue JSON::ParserError
          return false # non-JSON = not an E2B control-plane response
        end
        return false unless parsed.is_a?(Hash)

        code = parsed["code"].to_s.downcase
        type = parsed["type"].to_s.downcase
        return true if code.include?("sandbox") && (code.include?("not_found") || code.include?("not found") || code.include?("missing"))
        return true if type.include?("sandbox") && (type.include?("not_found") || type.include?("not found") || type.include?("missing"))

        %w[message error].each do |field|
          v = parsed[field].to_s.downcase
          next if v.empty?
          return true if SANDBOX_NOT_FOUND_MARKERS.any? { |m| v.include?(m) }
        end
        false
      end

      def write_file(path, content)
        uri = envd_uri("/files", user: "user", path: path)
        req = Net::HTTP::Post.new(uri)
        apply_envd_headers(req)
        req["Content-Type"] = "application/octet-stream"
        req.body = content
        perform_request(uri, req, what: "envd POST /files")
      end

      def read_file(path)
        uri = envd_uri("/files", user: "user", path: path)
        req = Net::HTTP::Get.new(uri)
        apply_envd_headers(req)
        perform_request(uri, req, what: "envd GET /files").body
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

        response = perform_request(uri, req, what: "envd exec")
        consume_exec_stream(response.body)
      end

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
        response = perform_request(uri, req, what: "control #{method.upcase} #{path}")
        return nil unless expect_json
        body = response.body.to_s
        body.empty? ? {} : JSON.parse(body)
      end

      # Retries only idempotent requests, so a 502 from a POST that may have
      # already taken effect (e.g. sandbox create) never fires twice.
      def perform_request(uri, req, what:)
        retries_left = IDEMPOTENT_METHODS.include?(req.method.upcase) ? @max_retries : 0
        attempt = 0

        loop do
          attempt += 1
          begin
            response = http_for(uri).request(req)
            code = response.code.to_i
            if retries_left > 0 && RETRIABLE_STATUSES.include?(code)
              retries_left -= 1
              sleep(backoff_for(attempt))
              next
            end
            raise_for_status!(response, code, what: what)
            return response
          rescue Net::OpenTimeout, Net::ReadTimeout => e
            raise TimeoutError, "#{what} timed out after #{attempt} attempts: #{e.message}" if retries_left <= 0
            retries_left -= 1
            sleep(backoff_for(attempt))
          rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
                 Errno::ENETUNREACH, SocketError => e
            raise ConnectError, "#{what} connect failed after #{attempt} attempts: #{e.class}: #{e.message}" if retries_left <= 0
            retries_left -= 1
            sleep(backoff_for(attempt))
          rescue OpenSSL::SSL::SSLError => e
            # Cert verification failures are terminal — no point retrying.
            raise ConnectError, "#{what} SSL failure: #{e.message}" if e.message =~ /certificate|hostname|verify/i
            raise ConnectError, "#{what} SSL failure after #{attempt} attempts: #{e.message}" if retries_left <= 0
            retries_left -= 1
            sleep(backoff_for(attempt))
          end
        end
      end

      def raise_for_status!(response, code, what:)
        return if code.between?(200, 299)
        raw_body = response.body.to_s
        preview = raw_body[0, 300]
        case code
        when 401, 403 then raise AuthError, "#{what}: #{code} #{preview}"
        when 404      then raise SandboxNotFound.new("#{what}: #{code} #{preview}", status: code, body: raw_body)
        when 500..599 then raise ServerError, "#{what}: #{code} #{preview}"
        else               raise HttpError.new(status: code, body: preview, message: "#{what}: HTTP #{code}: #{preview}")
        end
      end

      # Exponential backoff with jitter to avoid thundering-herd retries from
      # many sandboxes hitting the same transient failure.
      def backoff_for(attempt)
        RETRY_BACKOFF_BASE * (2**(attempt - 1)) * (1 + rand * 0.25)
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
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
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
