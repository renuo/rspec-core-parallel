require 'rspec/core/parallel'
RSpec::Core::Parallel.require_components
require 'rspec/core/sandbox'
require 'rspec/support/spec/with_isolated_directory'

Dir[File.join(__dir__, 'support/**/*.rb')].sort.each { |file| require file }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  config.example_status_persistence_file_path = 'tmp/examples.txt'

  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.mock_with(:rspec) { |c| c.verify_partial_doubles = true }
end
