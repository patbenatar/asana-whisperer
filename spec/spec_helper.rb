require "bundler/setup"

# Load application code without dotenv (tests don't need real API keys)
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "asana_whisperer/asana"
require "asana_whisperer/audio"
require "asana_whisperer/transcriber"
require "asana_whisperer/summarizer"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.order = :random
  Kernel.srand config.seed
end
