$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "agent_sandbox"
require "ruby_llm"

RubyLLM.configure do |c|
  c.openai_api_key = ENV.fetch("OPENAI_API_KEY")
end

MODEL = ENV.fetch("OPENAI_MODEL", "gpt-4o-mini")

sandbox = AgentSandbox.new(backend: :docker, image: "ruby:3.3-slim")

sandbox.with do |s|
  chat = RubyLLM.chat(model: MODEL)
  chat.with_tools(*AgentSandbox.ruby_llm_tools(s))

  prompt = <<~PROMPT
    You have a Ruby sandbox with tools: exec, write_file, read_file.
    Write a short Ruby program to /workspace/fizzbuzz.rb that prints fizzbuzz
    for 1..15, run it with `ruby /workspace/fizzbuzz.rb`, and tell me the exact
    output.
  PROMPT

  puts "--- prompt ---"
  puts prompt
  puts "--- model: #{MODEL} ---\n\n"

  reply = chat.ask(prompt)

  puts "--- final reply ---"
  puts reply.content
end
