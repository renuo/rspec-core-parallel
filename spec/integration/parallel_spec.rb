


RSpec.describe 'Running specs in parallel worker processes', :unless => RSpec::Support::OS.windows? || RSpec::Support::Ruby.jruby? do
  include_context 'project'

  def write_groups(count, examples_per_group=2)
    count.times do |index|
      write_file "spec/group_#{index}_spec.rb", "
        RSpec.describe 'Group #{index}' do
          #{examples_per_group}.times do |example_index|
            it(\"example \#{example_index}\") { expect(Process.pid).to be > 0 }
          end
        end
      "
    end
  end

  def worker_pids_from(file)
    File.read(expand_path(file)).split("\n").uniq
  end

  it 'runs every example exactly once and reports a combined summary' do
    write_groups(6)
    run_command "--parallel 3 spec"

    expect(last_cmd_exit_status).to eq(0)
    expect(normalize_durations(last_cmd_stdout)).to include("12 examples, 0 failures")
  end

  it 'runs examples in several processes other than the main one' do
    6.times do |index|
      write_file "spec/pid_#{index}_spec.rb", "
        RSpec.describe 'Group #{index}' do
          it('records its pid') do
            sleep 0.05
            File.open('pids', 'a') { |f| f.puts Process.pid }
          end
        end
      "
    end

    run_command "--parallel 3 spec"

    expect(last_cmd_exit_status).to eq(0)
    pids = worker_pids_from('pids')
    expect(pids.size).to be > 1
    expect(pids).not_to include(Process.pid.to_s)
  end

  it 'reports failures and pending examples like a sequential run' do
    write_file "spec/failing_spec.rb", "
      RSpec.describe 'Failing group' do
        it('fails') { expect(1).to eq(2) }
        it('raises') { raise ArgumentError, 'bad argument' }
        it('is pending') { pending('not yet'); raise 'still broken' }
        it('is skipped', :skip => 'later') { }
      end
    "
    write_groups(2)

    run_command "--parallel 2 --order defined spec"
    output = normalize_durations(last_cmd_stdout)

    expect(last_cmd_exit_status).to eq(1)
    expect(output).to include("8 examples, 2 failures, 2 pending")
    expect(output).to include(unindent(<<-EOS))
      Failures:

        1) Failing group fails
           Failure/Error: it('fails') { expect(1).to eq(2) }

             expected: 2
                  got: 1

             (compared using ==)
           # ./spec/failing_spec.rb:3:in #{quoted('block (2 levels) in <top (required)>')}

        2) Failing group raises
           Failure/Error: it('raises') { raise ArgumentError, 'bad argument' }

           ArgumentError:
             bad argument
           # ./spec/failing_spec.rb:4:in #{quoted('block (2 levels) in <top (required)>')}
    EOS
    expect(output).to include("rspec ./spec/failing_spec.rb:3 # Failing group fails")
    expect(output).to include("# not yet")
    expect(output).to include("# later")
  end

  it 'reports aggregated failures' do
    write_file "spec/aggregate_spec.rb", "
      RSpec.describe 'Aggregate' do
        it('fails twice', :aggregate_failures) do
          expect(1).to eq(2)
          expect(3).to eq(4)
        end
      end
    "
    write_groups(1)

    run_command "--parallel 2 spec"

    expect(last_cmd_exit_status).to eq(1)
    expect(last_cmd_stdout).to include("Got 2 failures:", "expected: 2", "expected: 4")
  end

  it 'reports exceptions that cannot be sent between processes using their class, message and backtrace' do
    write_file "spec/unmarshalable_spec.rb", "
      class UnmarshalableError < StandardError
        def initialize(message)
          super
          @callback = proc { }
        end
      end

      RSpec.describe 'Unmarshalable' do
        it('fails') { raise UnmarshalableError, 'cannot be dumped' }
      end
    "
    write_groups(1)

    run_command "--parallel 2 spec"

    expect(last_cmd_exit_status).to eq(1)
    expect(last_cmd_stdout).to include(
      "UnmarshalableError:\n       cannot be dumped\n     # ./spec/unmarshalable_spec.rb:10"
    )
  end

  it 'keeps the output of each top-level group together' do
    write_groups(4, 3)
    run_command "--parallel 4 --order defined --format documentation spec"

    4.times do |index|
      expect(last_cmd_stdout).to include(unindent(<<-EOS))
        Group #{index}
          example 0
          example 1
          example 2
      EOS
    end
  end

  it 'splits large groups across workers while keeping their output together' do
    write_file "spec/large_spec.rb", "
      RSpec.describe 'Large' do
        it('own example') { File.open('pids', 'a') { |f| f.puts Process.pid } }

        3.times do |index|
          describe(\"child \#{index}\") do
            it('first') { sleep 0.05; File.open('pids', 'a') { |f| f.puts Process.pid } }
            it('second') { }
          end
        end
      end
    "
    write_groups(1, 1)

    # The suite's sandbox registers a global `before(:context)` hook, which
    # would prevent groups from being split.
    RSpec::Core::Sandbox.sandboxed { run_command "--parallel 4 --order defined --format documentation spec" }

    expect(last_cmd_exit_status).to eq(0)
    expect(worker_pids_from('pids').size).to be > 1
    expect(last_cmd_stdout).to include("Large\n")
    expect(last_cmd_stdout.scan(/^Large$/).size).to eq(1)
    3.times do |index|
      expect(last_cmd_stdout).to include("  child #{index}\n    first\n    second\n")
    end
    large_output = last_cmd_stdout[/^Large\n(  .*\n)+/]
    expect(large_output.lines.size).to eq(11)
  end

  it 'runs the context hooks of split groups around each of their parts when configured to' do
    write_file "spec/large_spec.rb", "
      RSpec.configure { |c| c.parallel_split_groups_with_context_hooks = true }

      RSpec.describe 'Large' do
        before(:context) { @context = :set; File.open('hooks', 'a') { |f| f.puts 'before' } }
        after(:context) { File.open('hooks', 'a') { |f| f.puts 'after' } }

        it('own example') { expect(@context).to eq(:set) }
        2.times do |index|
          describe(\"child \#{index}\") do
            it('first') { sleep 0.05; expect(@context).to eq(:set) }
            it('second') { expect(@context).to eq(:set) }
          end
        end
      end
    "
    write_groups(1, 1)

    RSpec::Core::Sandbox.sandboxed { run_command "--parallel 4 spec" }

    expect(last_cmd_exit_status).to eq(0)
    expect(normalize_durations(last_cmd_stdout)).to include("6 examples, 0 failures")
    hooks = File.read(expand_path('hooks')).split("\n")
    expect(hooks.count('before')).to be > 1
    expect(hooks.count('after')).to eq(hooks.count('before'))
  end

  it 'runs suite hooks and parallel worker hooks in each worker, which get their own TEST_ENV_NUMBER' do
    write_file "spec/config_spec.rb", "
      RSpec.configure do |c|
        c.parallel_worker_setup do |number|
          File.open('setup', 'a') { |f| f.puts \"\#{number}:\#{ENV['TEST_ENV_NUMBER'].inspect}\" }
        end
        c.before(:suite) { File.open('before_suite', 'a') { |f| f.puts RSpec.configuration.parallel_worker_number } }
        c.after(:suite) { File.open('after_suite', 'a') { |f| f.puts RSpec.configuration.parallel_worker_number } }
        c.parallel_worker_teardown do |number|
          File.open('teardown', 'a') { |f| f.puts number }
        end
      end
    "
    write_groups(4)

    run_command "--parallel 2 spec"

    expect(last_cmd_exit_status).to eq(0)
    expect(File.read(expand_path('setup')).split("\n")).to contain_exactly('1:""', '2:"2"')
    expect(File.read(expand_path('before_suite')).split("\n")).to contain_exactly('1', '2')
    expect(File.read(expand_path('after_suite')).split("\n")).to contain_exactly('1', '2')
    expect(File.read(expand_path('teardown')).split("\n")).to contain_exactly('1', '2')
  end

  it 'runs `at_exit` hooks in the workers, so that tools like SimpleCov can save their results' do
    write_file "spec/at_exit_spec.rb", "
      RSpec.configure do |c|
        c.parallel_worker_setup do
          at_exit { File.open('#{expand_path('at_exit')}', 'a') { |f| f.puts Process.pid } }
        end
      end
    "
    write_groups(2)

    run_command "--parallel 2 spec"

    expect(last_cmd_exit_status).to eq(0)
    expect(worker_pids_from('at_exit').size).to eq(2)
  end

  it 'does not repeat output buffered before forking the workers' do
    write_groups(3)

    run_command "--parallel 3 --seed 1 --format progress --out progress.txt spec"

    expect(last_cmd_exit_status).to eq(0)
    expect(File.read(expand_path('progress.txt')).scan("Randomized with seed 1").size).to eq(2)
  end

  it 'reports errors raised in suite hooks of the workers' do
    write_file "spec/config_spec.rb", "
      RSpec.configure do |c|
        c.after(:suite) { raise 'boom' if RSpec.configuration.parallel_worker_number == 2 }
      end
    "
    write_groups(2)

    run_command "--parallel 2 spec"

    expect(last_cmd_exit_status).to eq(1)
    expect(normalize_durations(last_cmd_stdout)).to include(
      "An error occurred in an `after(:suite)` hook.",
      "4 examples, 0 failures, 1 error occurred outside of examples"
    )
  end

  it 'makes metadata set while running an example available to formatters' do
    write_file "metadata_formatter.rb", "
      class ParallelMetadataFormatter
        RSpec::Core::Formatters.register self, :example_passed

        def initialize(output)
          @output = output
        end

        def example_passed(notification)
          @output.puts \"screenshot: \#{notification.example.metadata[:screenshot]}\"
        end
      end
    "
    write_file "spec/metadata_spec.rb", "
      RSpec.describe 'Metadata' do
        it('sets metadata') { |example| example.metadata[:screenshot] = 'shot.png' }
      end
    "
    write_groups(1, 1)

    run_command "--require ./metadata_formatter.rb --format ParallelMetadataFormatter --parallel 2 spec"

    expect(last_cmd_exit_status).to eq(0)
    expect(last_cmd_stdout).to include("screenshot: shot.png")
  end

  it 'makes metadata changed in place while running an example available to formatters' do
    write_file "docs_formatter.rb", "
      class ParallelDocsFormatter
        RSpec::Core::Formatters.register self, :example_group_finished

        def initialize(output)
          @output = output
        end

        def example_group_finished(notification)
          @output.puts \"docs: \#{notification.group.metadata[:docs].inspect}\"
        end
      end
    "
    write_file "spec/docs_spec.rb", "
      RSpec.describe 'Docs', :docs => {} do
        it('documents') { |example| example.metadata[:docs][:status] = 200 }
      end
    "
    write_groups(1, 1)

    run_command "--require ./docs_formatter.rb --format ParallelDocsFormatter --parallel 2 spec"

    expect(last_cmd_exit_status).to eq(0)
    expect(last_cmd_stdout).to include("docs: {:status=>200}").or include("docs: {status: 200}")
  end

  it 'forwards custom events published from examples to formatters' do
    write_file "custom_formatter.rb", "
      class ParallelCustomEventFormatter
        RSpec::Core::Formatters.register self, :custom_event

        def initialize(output)
          @output = output
        end

        def custom_event(notification)
          @output.puts \"custom event: \#{notification.payload}\"
        end
      end
    "
    write_file "spec/publishing_spec.rb", "
      RSpec.describe 'Publishing' do
        it('publishes') { RSpec.configuration.reporter.publish(:custom_event, :payload => 'hello') }
      end
    "
    write_groups(1, 1)

    run_command "--require ./custom_formatter.rb --format ParallelCustomEventFormatter --parallel 2 spec"

    expect(last_cmd_exit_status).to eq(0)
    expect(last_cmd_stdout).to include("custom event: hello")
  end

  it 'fails the example running when its worker dies, and keeps reporting the other groups' do
    write_file "spec/exiting_spec.rb", "
      RSpec.describe 'Exiting group' do
        context 'nested' do
          it('passes') { }
          it('exits') { exit!(3) }
        end
      end
    "
    write_groups(2, 1)

    run_command "--parallel 2 --order defined --format documentation spec"

    expect(last_cmd_exit_status).to eq(1)
    expect(last_cmd_stdout).to include("Exiting group\n  nested\n    passes\n    exits (FAILED - 1)\n")
    expect(last_cmd_stdout).to match(/^Group 0\n  example 0\n/).and match(/^Group 1\n  example 0\n/)
    expect(last_cmd_stdout).to match(/Parallel worker \d \(pid \d+\) exited unexpectedly while running `Exiting group( nested)?`/)
    expect(normalize_durations(last_cmd_stdout)).to include("4 examples, 1 failure")
  end

  it 'exits with the status given to `exit` by an example, like a sequential run' do
    write_file "spec/exit_spec.rb", "
      RSpec.describe 'Exit' do
        it('exits') { exit 3 }
      end
    "
    write_groups(2)

    expect { run_command "--parallel 2 spec" }.to raise_error(SystemExit) { |error| expect(error.status).to eq(3) }
  end

  it 'reports values set in metadata whose class the main process does not know' do
    write_file "spec/metadata_spec.rb", "
      RSpec.describe 'Metadata' do
        it('defines a class') { |ex| Object.const_set(:DefinedInWorker, Struct.new(:v)); ex.metadata[:thing] = DefinedInWorker.new(1) }
      end
    "
    write_groups(1, 1)

    run_command "--parallel 2 spec"

    expect(last_cmd_exit_status).to eq(0)
    expect(normalize_durations(last_cmd_stdout)).to include("2 examples, 0 failures")
  end

  it 'does not wait for processes started by examples which outlive their worker' do
    write_file "spec/daemon_spec.rb", "
      RSpec.describe 'Daemon' do
        it('starts a long running process') { Process.detach(fork { [$stdout, $stderr].each { |io| io.reopen(File::NULL) }; sleep 10 }) }
      end
    "
    write_groups(1, 1)

    started_at = Time.now
    run_command "--parallel 2 spec"

    expect(last_cmd_exit_status).to eq(0)
    expect(Time.now - started_at).to be < 5
  end

  it 'stops the examples running in other workers once the fail fast limit is met' do
    write_file "spec/failing_spec.rb", "
      RSpec.describe 'Failing group' do
        it('fails') { sleep 0.2; expect(1).to eq(2) }
      end
    "
    write_file "spec/slow_spec.rb", "
      RSpec.describe 'Slow group', :parallel_split => false do
        30.times { |index| it(\"example \#{index}\") { sleep 0.05 } }
      end
    "

    run_command "--parallel 2 --fail-fast spec"

    expect(last_cmd_exit_status).to eq(1)
    expect(normalize_durations(last_cmd_stdout)[/(\d+) examples?, 1 failure/, 1].to_i).to be < 20
  end

  it 'stops dispatching groups once the fail fast limit is met' do
    write_file "spec/failing_spec.rb", "
      RSpec.describe 'Failing group' do
        it('fails') { expect(1).to eq(2) }
      end
    "
    20.times do |index|
      write_file "spec/slow_#{index}_spec.rb", "RSpec.describe('Slow #{index}') { it('sleeps') { sleep 0.05 } }"
    end

    run_command "--parallel 2 --fail-fast --order defined spec"

    expect(last_cmd_exit_status).to eq(1)
    examples_run = normalize_durations(last_cmd_stdout)[/(\d+) examples?, 1 failure/, 1].to_i
    expect(examples_run).to be < 21
  end

  it 'persists example statuses so that `--only-failures` works' do
    write_file "spec/failing_spec.rb", "
      RSpec.configure { |c| c.example_status_persistence_file_path = 'examples.txt' }

      RSpec.describe 'Failing group' do
        it('fails') { expect(1).to eq(2) }
      end
    "
    write_groups(2)

    run_command "--parallel 2 spec"
    expect(last_cmd_exit_status).to eq(1)

    run_command "--parallel 2 --only-failures spec/failing_spec.rb"
    expect(normalize_durations(last_cmd_stdout)).to include("1 example, 1 failure")
  end

  it 'persists the run times of the examples in the `tmp` directory, to schedule the next runs' do
    write_groups(2)
    FileUtils.mkdir_p(expand_path('tmp'))

    run_command "--parallel 2 spec"

    expect(last_cmd_exit_status).to eq(0)
    run_times = RSpec::Core::ExampleStatusPersister.load_from(expand_path('tmp/rspec_parallel_run_times.txt'))
    expect(run_times.map { |example| example[:example_id] }).to include("./spec/group_0_spec.rb[1:1]")
    expect(run_times.map { |example| example[:run_time] }).to all(end_with("seconds"))
  end

  it 'persists run times in a new `tmp` directory when the project has none' do
    write_groups(2)

    run_command "--parallel 2 spec"

    expect(last_cmd_exit_status).to eq(0)
    expect(File.exist?(expand_path('tmp/rspec_parallel_run_times.txt'))).to be(true)
  end

  it 'runs sequentially, with a warning, where processes cannot be forked' do
    allow(RSpec::Core::Parallel).to receive(:supported?).and_return(false)
    2.times do |index|
      write_file "spec/pid_#{index}_spec.rb", "
        RSpec.describe 'Group #{index}' do
          it('records its pid') { File.open('pids', 'a') { |f| f.puts Process.pid } }
        end
      "
    end

    run_command "--parallel 2 spec"

    expect(last_cmd_exit_status).to eq(0)
    expect(last_cmd_stderr).to include("Running specs in parallel requires `Process.fork`")
    expect(worker_pids_from('pids')).to eq([Process.pid.to_s])
  end

  it 'runs sequentially when there is only one group' do
    write_file "spec/pid_spec.rb", "
      RSpec.describe 'Group' do
        it('records its pid') { File.write('pid', Process.pid) }
      end
    "

    run_command "--parallel 4 spec"

    expect(last_cmd_exit_status).to eq(0)
    expect(File.read(expand_path('pid'))).to eq(Process.pid.to_s)
  end
end
