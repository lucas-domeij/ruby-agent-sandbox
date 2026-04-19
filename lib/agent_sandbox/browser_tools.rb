require "ruby_llm"
require "json"
require "shellwords"
require "tempfile"
require "base64"

module AgentSandbox
  # RubyLLM tool adapters for Vercel's `agent-browser` CLI running inside
  # a sandbox. The sandbox image must have agent-browser + a chromium-
  # compatible browser installed (see docker/browser.Dockerfile).
  #
  #   sandbox = AgentSandbox.new(backend: :docker, image: "agent-sandbox-browser",
  #                              hardened: false, memory: "2g")
  #   chat = RubyLLM.chat(model: "gpt-4o-mini")
  #   chat.with_tools(*AgentSandbox.browser_tools(sandbox))
  #
  # Pass `vision_model:` to override the model used by `screenshot` and
  # `read_image` (those tools take a second LLM hop to extract text from
  # the image). Default is ENV["AGENT_SANDBOX_VISION_MODEL"] or "gpt-5".
  #
  # The `agent-browser` daemon persists browser state (tabs, cookies) across
  # invocations, so each tool call reuses the same Chrome session.
  module BrowserTools
    def self.build(sandbox, vision_model: nil)
      vm = vision_model || ENV["AGENT_SANDBOX_VISION_MODEL"] || "gpt-5"
      [
        Open.new(sandbox),
        Snapshot.new(sandbox),
        Click.new(sandbox),
        Fill.new(sandbox),
        GetText.new(sandbox),
        Wait.new(sandbox),
        Back.new(sandbox),
        Reload.new(sandbox),
        Screenshot.new(sandbox, vision_model: vm),
        Eval.new(sandbox),
        ReadImage.new(sandbox, vision_model: vm)
      ]
    end

    class Base < RubyLLM::Tool
      def initialize(sandbox)
        @sandbox = sandbox
        super()
      end

      # agent-browser emits `{success:, data:, error:}` JSON on --json. Return
      # data on success, a structured error hash otherwise, so the LLM always
      # sees something it can reason about instead of opaque exit-status noise.
      def run_ab(args)
        cmd = "agent-browser " + args.map { |a| Shellwords.escape(a) }.join(" ")
        result = @sandbox.exec(cmd)
        parsed = parse_json(result.stdout) || parse_json(result.stderr)
        if parsed
          if parsed["success"]
            parsed["data"] || {}
          else
            { error: parsed["error"] || "agent-browser reported failure",
              stdout: truncate(result.stdout), stderr: truncate(result.stderr) }
          end
        else
          { error: "non-JSON output", status: result.status,
            stdout: truncate(result.stdout), stderr: truncate(result.stderr) }
        end
      end

      private

      def parse_json(str)
        return nil if str.nil? || str.strip.empty?
        JSON.parse(str.strip.lines.last.to_s)
      rescue JSON::ParserError
        nil
      end

      def truncate(str, limit: 4000)
        return str if str.to_s.length <= limit
        str[0, limit] + "\n…[truncated #{str.length - limit} chars]"
      end
    end

    # Mixin: download bytes out of the sandbox into a host tempfile, run a
    # multimodal sub-call on the image, and clean up the tempfile right
    # after. Keeps no global state — each call is self-contained.
    module VisionSupport
      DEFAULT_FOCUS_PROMPT = lambda { |focus|
        "Read this image. Focus on: #{focus}. Return structured plain " \
          "text. Quote exact numbers and labels as they appear. If " \
          "something isn't visible, say so instead of guessing."
      }

      DEFAULT_GENERAL_PROMPT =
        "Describe this image. List every product, price, heading, and " \
        "notable text you see. Be exact with numbers and labels."

      def self.read_image_bytes(bytes, extension:, focus:, vision_model:)
        tmp = Tempfile.new(["agent-vision", ".#{extension}"])
        tmp.binmode
        tmp.write(bytes)
        tmp.close
        begin
          prompt = focus && !focus.empty? ? DEFAULT_FOCUS_PROMPT.call(focus) : DEFAULT_GENERAL_PROMPT
          chat = RubyLLM.chat(model: vision_model)
          reply = chat.ask(prompt, with: tmp.path)
          reply.content
        ensure
          tmp.close! rescue nil
        end
      end
    end

    class Open < Base
      description "Navigate the browser to a URL. Waits for the page to load before returning."
      param :url, desc: "Absolute URL, e.g. https://example.com"

      def execute(url:)
        run_ab(["open", url, "--json"])
      end
    end

    class Snapshot < Base
      description <<~DESC
        Take an accessibility-tree snapshot of the current page. Returns a
        compact tree where each interactive element has a @e1, @e2, …
        reference you can pass to click/fill/get_text. Use this after
        navigating to find what's on the page.
      DESC
      param :interactive_only, type: :boolean, required: false,
            desc: "If true (default), only include clickable/focusable elements. Pass false to include the full DOM tree."

      def execute(interactive_only: true)
        args = ["snapshot", "--json"]
        args << "-i" if interactive_only
        run_ab(args)
      end
    end

    class Click < Base
      description "Click the element identified by ref (e.g. 'e1' or '@e1')."
      param :ref, desc: "Element ref from the latest snapshot, e.g. 'e3' or '@e3'."

      def execute(ref:)
        run_ab(["click", normalize_ref(ref), "--json"])
      end

      private

      def normalize_ref(r) = r.start_with?("@") ? r : "@#{r}"
    end

    class Fill < Base
      description "Fill an input/textarea identified by ref with the given text."
      param :ref, desc: "Element ref from the latest snapshot, e.g. 'e2' or '@e2'."
      param :text, desc: "Text to fill into the field."

      def execute(ref:, text:)
        run_ab(["fill", normalize_ref(ref), text, "--json"])
      end

      private

      def normalize_ref(r) = r.start_with?("@") ? r : "@#{r}"
    end

    class GetText < Base
      description "Get the visible text content of the element identified by ref."
      param :ref, desc: "Element ref, e.g. 'e4' or '@e4'."

      def execute(ref:)
        run_ab(["get", "text", normalize_ref(ref), "--json"])
      end

      private

      def normalize_ref(r) = r.start_with?("@") ? r : "@#{r}"
    end

    class Wait < Base
      description "Wait for a condition: either a number of milliseconds, or until a CSS/text condition is met. Prefer short waits (<3000ms) — agents should use snapshot to find elements instead of polling."
      param :milliseconds, type: :integer, required: false,
            desc: "Fixed wait in milliseconds, e.g. 1500"
      param :text, required: false,
            desc: "Wait until this text appears on the page"

      def execute(milliseconds: nil, text: nil)
        if text
          run_ab(["wait", "--text", text, "--json"])
        elsif milliseconds
          run_ab(["wait", milliseconds.to_s, "--json"])
        else
          { error: "pass either milliseconds or text" }
        end
      end
    end

    class Back < Base
      description "Navigate back in browser history."
      def execute = run_ab(["back", "--json"])
    end

    class Reload < Base
      description "Reload the current page."
      def execute = run_ab(["reload", "--json"])
    end

    # Screenshots the current viewport and "reads" it by running a
    # sub-request against a multimodal model. Returns the description as
    # text so the main tool-loop isn't constrained by OpenAI's rule that
    # only role:user messages may contain images.
    class Screenshot < Base
      description <<~DESC
        Take a PNG screenshot of the current viewport, ask a vision model
        to describe/extract what's on it, and return the description as
        text. Use this for canvas-rendered content (PDF flipbooks, charts,
        maps, image-heavy pages) where snapshot/get_text returns nothing.

        Pass a `focus` hint to steer what the vision model looks for
        (e.g. "product names and prices in SEK"); default is a general
        description.
      DESC
      param :focus, required: false,
            desc: "What the vision model should focus on, e.g. 'product names and prices in SEK'."

      def initialize(sandbox, vision_model:)
        @vision_model = vision_model
        super(sandbox)
      end

      def execute(focus: nil)
        sandbox_path = "/tmp/agent-shot-#{Time.now.to_f.to_s.tr('.', '')}.png"
        data = run_ab(["screenshot", sandbox_path, "--json"])
        return data if data.is_a?(Hash) && data[:error]

        bytes = @sandbox.read_file(sandbox_path)
        @sandbox.exec("rm -f #{Shellwords.escape(sandbox_path)}")

        description = VisionSupport.read_image_bytes(
          bytes, extension: "png", focus: focus, vision_model: @vision_model
        )
        { description: description, bytes: bytes.bytesize, vision_model: @vision_model }
      end
    end

    class Eval < Base
      description <<~DESC
        Run a JavaScript expression in the current page context and return
        its result as JSON. Useful for: extracting structured data the DOM
        exposes (window.__NEXT_DATA__, Redux state), peeking at the current
        URL of an iframe, or fishing out flipbook/canvas metadata that
        snapshot can't see.
      DESC
      param :js, desc: "JavaScript expression, e.g. 'document.title' or 'JSON.stringify(window.__NEXT_DATA__)'."

      def execute(js:)
        run_ab(["eval", js, "--json"])
      end
    end

    # Downloads an image URL from inside the sandbox and asks a vision
    # model to read it. Ideal for brochures/flipbooks where product pages
    # are served as discoverable <img> URLs — higher resolution than a
    # viewport screenshot, and skips browser chrome entirely.
    class ReadImage < Base
      description <<~DESC
        Download an image from a URL (inside the sandbox) and ask a vision
        model to describe / extract text from it. Use this on product
        pages, brochure/flipbook images, charts or any image whose URL you
        discovered via eval or snapshot.

        Pass a `focus` hint to steer what to extract, e.g.
        "product names and prices in SEK, including any discount percent".
      DESC
      param :url, desc: "Absolute image URL, e.g. https://cdn.example.com/page-1.jpg"
      param :focus, required: false,
            desc: "What the vision model should focus on."

      def initialize(sandbox, vision_model:)
        @vision_model = vision_model
        super(sandbox)
      end

      def execute(url:, focus: nil)
        # Fetch through the current page's fetch() so cookies + origin
        # headers from the live session are sent (image URLs on logged-in
        # pages commonly require them). Fall back to a direct download if
        # there's no page context or the in-page fetch refuses (CORS etc).
        bytes, content_type, session_error = fetch_via_session(url)
        if bytes.nil?
          bytes, content_type, curl_error = fetch_via_curl(url)
          if bytes.nil?
            return { error: "download failed", url: url,
                     session_error: session_error, curl_error: curl_error }
          end
        end

        unless content_type.to_s.start_with?("image/")
          return { error: "not an image", url: url, content_type: content_type,
                   bytes: bytes.bytesize,
                   hint: "response wasn't image/* — often a redirect to an HTML login/CAPTCHA page. Try opening the URL in the browser first to authenticate, then retry." }
        end

        description = VisionSupport.read_image_bytes(
          bytes, extension: content_type_to_ext(content_type) || "img",
          focus: focus, vision_model: @vision_model
        )
        { description: description, url: url, content_type: content_type,
          vision_model: @vision_model }
      end

      private

      def fetch_via_session(url)
        js = <<~JS
          (async () => {
            try {
              const r = await fetch(#{url.to_json}, { credentials: "include" });
              if (!r.ok) return { ok: false, error: "HTTP " + r.status };
              const ct = r.headers.get("content-type") || "";
              const buf = await r.arrayBuffer();
              const u8 = new Uint8Array(buf);
              let bin = "";
              const chunk = 0x8000;
              for (let i = 0; i < u8.length; i += chunk) {
                bin += String.fromCharCode.apply(null, u8.subarray(i, i + chunk));
              }
              return { ok: true, contentType: ct, dataBase64: btoa(bin) };
            } catch (e) {
              return { ok: false, error: String(e && e.message || e) };
            }
          })()
        JS
        data = run_ab(["eval", js, "--json"])
        return [nil, nil, data[:error]] if data.is_a?(Hash) && data[:error]
        result = data.is_a?(Hash) ? (data["result"] || data[:result]) : nil
        return [nil, nil, "eval returned #{data.inspect[0, 200]}"] unless result.is_a?(Hash)
        return [nil, nil, result["error"]] unless result["ok"]
        [Base64.decode64(result["dataBase64"].to_s), result["contentType"].to_s, nil]
      end

      def fetch_via_curl(url)
        sandbox_path = "/tmp/agent-img-#{Time.now.to_f.to_s.tr('.', '')}"
        result = @sandbox.exec(
          "curl -fsSL -o #{Shellwords.escape(sandbox_path)} " \
            "-w '%{content_type}' #{Shellwords.escape(url)}"
        )
        unless result.success?
          return [nil, nil, "status=#{result.status} stderr=#{result.stderr[0, 200]}"]
        end
        content_type = result.stdout.strip
        bytes = @sandbox.read_file(sandbox_path)
        @sandbox.exec("rm -f #{Shellwords.escape(sandbox_path)}")
        [bytes, content_type, nil]
      end

      def content_type_to_ext(ct)
        case ct.to_s
        when %r{image/png} then "png"
        when %r{image/jpe?g} then "jpg"
        when %r{image/webp} then "webp"
        when %r{image/gif} then "gif"
        end
      end
    end
  end
end
