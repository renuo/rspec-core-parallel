require 'fileutils'
require 'shellwords'
require 'stringio'
require 'tmpdir'

# Runs rspec in-process against spec files written to a temporary directory.
RSpec.shared_context 'project' do
  OWN_SPECS = %r{\A#{Regexp.escape(File.expand_path('..', __dir__))}/}.freeze

  attr_reader :last_cmd_stdout, :last_cmd_stderr, :last_cmd_exit_status

  around do |example|
    Dir.mktmpdir('rspec-core-parallel') do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  def write_file(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def expand_path(path)
    File.expand_path(path)
  end

  def run_command(cmd)
    stdout = StringIO.new
    stderr = StringIO.new
    # So that `RSpec.warning` goes to stderr.
    allow(::Kernel).to receive(:warn) { |message| stderr.puts(message) }

    RSpec::Core::Sandbox.sandboxed do
      # Memoizes the current directory: reset it for the project directory, then for ours.
      RSpec::Core::Metadata.instance_variable_set(:@relative_path_regex, nil)
      RSpec.configuration.backtrace_exclusion_patterns << OWN_SPECS
      @last_cmd_exit_status = RSpec::Core::Runner.run(['--no-profile'] + Shellwords.split(cmd), stderr, stdout)
    end
  ensure
    RSpec::Core::Metadata.instance_variable_set(:@relative_path_regex, nil)
    @last_cmd_stdout = stdout.string
    @last_cmd_stderr = stderr.string
  end

  def unindent(string)
    string.gsub(/^#{string.scan(/^[ \t]+(?=\S)/).min}/, '')
  end

  def quoted(string)
    RUBY_VERSION.to_f > 3.3 ? "'#{string}'" : "`#{string}'"
  end

  def normalize_durations(output)
    output.gsub(/(?:\d+ minutes? )?\d+(?:\.\d+)?(s| seconds?)/) do
      "n.nnnn#{Regexp.last_match(1) == 's' ? 's' : ' seconds'}"
    end
  end
end
