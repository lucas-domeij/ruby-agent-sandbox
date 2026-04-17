$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "agent_sandbox"

module TestHelper
  def self.runner
    fails = []
    assert = ->(label, cond, detail = nil) {
      if cond
        puts "  ok  #{label}"
      else
        puts "FAIL  #{label}  #{detail}"
        fails << label
      end
    }
    [fails, assert]
  end

  def self.done(fails, label:)
    if fails.empty?
      puts "\n#{label}: all good"
      exit 0
    else
      puts "\nFAIL: #{fails.inspect}"
      exit 1
    end
  end
end
