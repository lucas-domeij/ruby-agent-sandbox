require_relative "test_helper"
require "agent_sandbox/browser_tools"
require "base64"
require "json"

fails, assert = TestHelper.runner

# --- fakes ------------------------------------------------------------------
# FakeSandbox records every exec command and returns scripted responses. Each
# script entry may set stdout, stderr, status, or be a Proc that receives the
# command string and returns an ExecResult.
FakeExecResult = Struct.new(:stdout, :stderr, :status) do
  def success? = status.to_i == 0
end

class FakeSandbox
  attr_reader :exec_log, :read_log, :files

  def initialize
    @script = []
    @exec_log = []
    @read_log = []
    @files = {}
  end

  def push(stdout: "", stderr: "", status: 0, &block)
    @script << (block || FakeExecResult.new(stdout, stderr, status))
    self
  end

  def push_file(path, bytes)
    @files[path] = bytes
    self
  end

  def exec(command)
    @exec_log << command
    entry = @script.shift
    raise "FakeSandbox: no scripted response for #{command.inspect}" unless entry
    return entry.call(command) if entry.respond_to?(:call)
    entry
  end

  def read_file(path)
    @read_log << path
    @files[path] || raise("FakeSandbox: no file at #{path.inspect}")
  end
end

def ab_ok(data)  = JSON.generate(success: true, data: data, error: nil)
def ab_fail(msg) = JSON.generate(success: false, data: nil, error: msg)

# --- Open -------------------------------------------------------------------
puts "[Open]"
sb = FakeSandbox.new.push(stdout: ab_ok(title: "Hi", url: "https://ex.com/"))
data = AgentSandbox::BrowserTools::Open.new(sb).execute(url: "https://ex.com/")
assert.("open returns unwrapped data", data["title"] == "Hi", data.inspect)
assert.("open invokes agent-browser", sb.exec_log.first.start_with?("agent-browser open"),
        sb.exec_log.first)

# --- Snapshot ---------------------------------------------------------------
puts "[Snapshot]"
sb = FakeSandbox.new.push(stdout: ab_ok(refs: { e1: { role: "button" } }, snapshot: "..."))
data = AgentSandbox::BrowserTools::Snapshot.new(sb).execute
assert.("snapshot parses refs", data["refs"]["e1"]["role"] == "button", data.inspect)
assert.("snapshot default passes -i", sb.exec_log.first.include?(" -i"), sb.exec_log.first)

sb = FakeSandbox.new.push(stdout: ab_ok({}))
AgentSandbox::BrowserTools::Snapshot.new(sb).execute(interactive_only: false)
assert.("snapshot(full) omits -i", !sb.exec_log.first.include?(" -i "), sb.exec_log.first)

# --- Click / Fill / GetText normalize @ref ---------------------------------
puts "[Click/Fill/GetText ref normalization]"
[
  [AgentSandbox::BrowserTools::Click,    ->(t) { t.execute(ref: "e3") },           "click @e3"],
  [AgentSandbox::BrowserTools::Click,    ->(t) { t.execute(ref: "@e3") },          "click @e3"],
  [AgentSandbox::BrowserTools::Fill,     ->(t) { t.execute(ref: "e2", text: "x") }, "fill @e2"],
  [AgentSandbox::BrowserTools::GetText,  ->(t) { t.execute(ref: "e4") },           "get text @e4"]
].each do |klass, call, expected_fragment|
  sb = FakeSandbox.new.push(stdout: ab_ok({}))
  call.call(klass.new(sb))
  cmd = sb.exec_log.first
  assert.("#{klass.name.split('::').last} emits `#{expected_fragment}`",
          cmd.include?(expected_fragment), cmd)
end

# --- Wait: text uses --text (regression from codex review) -----------------
puts "[Wait]"
sb = FakeSandbox.new.push(stdout: ab_ok(waited: "text"))
AgentSandbox::BrowserTools::Wait.new(sb).execute(text: "hello")
cmd = sb.exec_log.first
assert.("wait(text:) uses --text flag", cmd.include?(" --text "), cmd)
assert.("wait(text:) does NOT pass bare 'text' arg",
        cmd !~ /\bwait text hello\b/, cmd)

sb = FakeSandbox.new.push(stdout: ab_ok(waited: "timeout"))
AgentSandbox::BrowserTools::Wait.new(sb).execute(milliseconds: 500)
assert.("wait(ms) passes numeric arg", sb.exec_log.first =~ /wait 500\b/, sb.exec_log.first)

res = AgentSandbox::BrowserTools::Wait.new(FakeSandbox.new).execute
assert.("wait() with neither arg returns error", res[:error], res.inspect)

# --- run_ab: success vs error vs non-JSON ----------------------------------
puts "[run_ab error handling]"
sb = FakeSandbox.new.push(stdout: ab_fail("no browser session"))
data = AgentSandbox::BrowserTools::Back.new(sb).execute
assert.("failure JSON surfaces :error", data[:error] == "no browser session", data.inspect)

sb = FakeSandbox.new.push(stdout: "not json at all", status: 1)
data = AgentSandbox::BrowserTools::Reload.new(sb).execute
assert.("non-JSON stdout surfaces :error", data[:error] == "non-JSON output", data.inspect)

# --- ReadImage -------------------------------------------------------------
# Stub VisionSupport so tests don't call a real vision model.
module AgentSandbox::BrowserTools::VisionSupport
  class << self
    attr_accessor :last_call
    def read_image_bytes(bytes, extension:, focus:, vision_model:)
      self.last_call = { bytes: bytes, extension: extension, focus: focus, vision_model: vision_model }
      "STUB DESCRIPTION (#{bytes.bytesize}B #{extension})"
    end
  end
end

puts "[ReadImage: session fetch happy path]"
AgentSandbox::BrowserTools::VisionSupport.last_call = nil
png = "\x89PNG\r\n\x1a\n".b + "rest-of-png-bytes".b
eval_result = ab_ok(
  origin: "https://site/",
  result: { "ok" => true, "contentType" => "image/png", "dataBase64" => Base64.strict_encode64(png) }
)
sb = FakeSandbox.new.push(stdout: eval_result)
tool = AgentSandbox::BrowserTools::ReadImage.new(sb, vision_model: "test-vision")
data = tool.execute(url: "https://site/img.png", focus: "the cat")
assert.("read_image first tries session fetch (eval)",
        sb.exec_log.first.start_with?("agent-browser eval"), sb.exec_log.first)
assert.("read_image returns content_type from session fetch",
        data[:content_type] == "image/png", data.inspect)
assert.("read_image returns vision description",
        data[:description].start_with?("STUB DESCRIPTION"), data.inspect)
last = AgentSandbox::BrowserTools::VisionSupport.last_call
assert.("vision receives decoded bytes", last[:bytes] == png, last.inspect)
assert.("vision receives png extension", last[:extension] == "png", last.inspect)
assert.("vision receives focus", last[:focus] == "the cat", last.inspect)
assert.("vision receives injected model", last[:vision_model] == "test-vision", last.inspect)

puts "[ReadImage: non-image content_type is rejected before vision]"
AgentSandbox::BrowserTools::VisionSupport.last_call = nil
html = "<!doctype html><html>login</html>"
eval_result = ab_ok(
  origin: "https://site/",
  result: { "ok" => true, "contentType" => "text/html; charset=utf-8", "dataBase64" => Base64.strict_encode64(html) }
)
sb = FakeSandbox.new.push(stdout: eval_result)
data = AgentSandbox::BrowserTools::ReadImage.new(sb, vision_model: "test-vision")
  .execute(url: "https://site/login")
assert.("non-image returns :error", data[:error] == "not an image", data.inspect)
assert.("non-image preserves content_type", data[:content_type].start_with?("text/html"), data.inspect)
assert.("non-image does NOT invoke vision",
        AgentSandbox::BrowserTools::VisionSupport.last_call.nil?, "vision was called anyway")

puts "[ReadImage: falls back to curl when session fetch fails]"
AgentSandbox::BrowserTools::VisionSupport.last_call = nil
jpg = "\xFF\xD8\xFF".b + "more-jpg".b
curl_cmd_seen = nil
sb = FakeSandbox.new
# 1. eval fetch: in-page fetch errored (CORS-style)
sb.push(stdout: ab_ok(origin: "about:blank",
                      result: { "ok" => false, "error" => "TypeError: fetch" }))
# 2. curl -fsSL ... (writes body to sandbox_path; stdout is content_type via -w)
sb.push do |cmd|
  curl_cmd_seen = cmd
  path = cmd[/-o (\S+)/, 1]
  sb.push_file(path.gsub(/\\/, ""), jpg) # strip Shellwords escapes if any (none in our fakes)
  FakeExecResult.new("image/jpeg", "", 0)
end
# 3. rm -f cleanup
sb.push(stdout: "", status: 0)

data = AgentSandbox::BrowserTools::ReadImage.new(sb, vision_model: "test-vision")
  .execute(url: "https://cdn.example/pic.jpg")
assert.("fallback invoked curl", curl_cmd_seen&.start_with?("curl "), curl_cmd_seen.inspect)
assert.("fallback returns image/jpeg", data[:content_type] == "image/jpeg", data.inspect)
assert.("fallback calls vision with jpg ext",
        AgentSandbox::BrowserTools::VisionSupport.last_call&.dig(:extension) == "jpg",
        AgentSandbox::BrowserTools::VisionSupport.last_call.inspect)

# --- Screenshot ------------------------------------------------------------
puts "[Screenshot]"
AgentSandbox::BrowserTools::VisionSupport.last_call = nil
png = "\x89PNG\r\n\x1a\n".b + "shot-bytes".b
sb = FakeSandbox.new
sb.push do |cmd|
  # agent-browser screenshot <path> --json
  path = cmd.split.find { |part| part.start_with?("/tmp/agent-shot") }
  sb.push_file(path, png)
  FakeExecResult.new(ab_ok(path: path), "", 0)
end
sb.push(stdout: "", status: 0) # rm -f

data = AgentSandbox::BrowserTools::Screenshot.new(sb, vision_model: "shot-vision")
  .execute(focus: "prices")
assert.("screenshot returns bytes size", data[:bytes] == png.bytesize, data.inspect)
assert.("screenshot returns description", data[:description].start_with?("STUB"), data.inspect)
last = AgentSandbox::BrowserTools::VisionSupport.last_call
assert.("screenshot passes focus to vision", last[:focus] == "prices", last.inspect)
assert.("screenshot uses injected vision model", last[:vision_model] == "shot-vision", last.inspect)

TestHelper.done(fails, label: "browser_tools")
