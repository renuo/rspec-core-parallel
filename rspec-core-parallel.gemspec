require_relative 'lib/rspec/core/parallel/version'

Gem::Specification.new do |spec|
  spec.name = 'rspec-core-parallel'
  spec.version = RSpec::Core::Parallel::VERSION
  spec.authors = ['Alessandro Rodi']
  spec.email = ['alessandro.rodi@renuo.ch']
  spec.summary = 'Run an RSpec suite in forked worker processes: rspec --parallel'
  spec.description = 'Adds `rspec --parallel` to rspec-core 3.13: the suite is loaded once, forked into ' \
                     'one worker per CPU core, and groups are handed out longest first using the run times ' \
                     'of the previous run. Formatters, --only-failures, --bisect and exit codes work as in ' \
                     'a sequential run. Rails apps get a test database per worker.'
  spec.homepage = 'https://github.com/renuo/rspec-core-parallel'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.3'

  spec.metadata = {
    'homepage_uri' => spec.homepage,
    'source_code_uri' => spec.homepage,
    'changelog_uri' => "#{spec.homepage}/blob/main/CHANGELOG.md",
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir['lib/**/*.rb', 'exe/*', 'README.md', 'CHANGELOG.md', 'LICENSE.md']
  spec.bindir = 'exe'
  spec.executables = ['rspec-parallel']
  spec.require_paths = ['lib']

  # Patches private rspec-core internals: every minor version needs to be checked.
  spec.add_dependency 'rspec-core', '>= 3.13.0', '< 3.14'
end
