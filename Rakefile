require "rake/testtask"

# Unit tests that don't need Docker or an E2B API key. These are the ones
# safe to run in CI and on a fresh checkout.
UNIT_TESTS = FileList[
  "test/docker_port_parse_test.rb",
  "test/e2b_frames_test.rb",
  "test/e2b_error_mapping_test.rb"
]

desc "Run unit tests (no Docker / no network)"
task :test do
  UNIT_TESTS.each do |f|
    sh Gem.ruby, "-Ilib", f
  end
end

task default: :test
