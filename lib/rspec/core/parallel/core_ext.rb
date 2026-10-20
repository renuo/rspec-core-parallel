require 'rspec/core/bisect/shell_command'
require 'rspec/core/bisect/fork_runner'

module RSpec
  module Core
    module Parallel
      # The changes rspec-core needs to run a suite in parallel, applied to
      # rspec-core 3.13 from outside.
      #
      # @private
      module CoreExt
        # @private
        module Configuration
          # @private
          DEFAULT_PARALLEL_RUN_TIMES_FILE_PATH = 'tmp/rspec_parallel_run_times.txt'

          def self.included(configuration)
            # @macro add_setting
            # Number of worker processes used to run the suite (default: 1,
            # which runs the suite sequentially in the current process). The
            # suite is loaded once and then forked, so every worker is a
            # separate process: examples running concurrently never share
            # global state. Each worker runs `before(:suite)` and
            # `after(:suite)` hooks, and gets a `TEST_ENV_NUMBER` environment
            # variable (`""`, `"2"`, `"3"`...) which can be used to give every
            # worker its own database.
            # @return [Integer]
            configuration.add_setting :parallel_workers

            # @macro add_setting
            # Allows parallel runs to split groups having `before(:context)` or
            # `after(:context)` hooks across workers (default: `false`).
            #
            # A top-level group expected to take longer than a worker's share
            # of the suite is split into its child groups and parts of its
            # examples, which run in different workers. By default only groups
            # without context hooks of their own (global ones are fine) are
            # split, since the context hooks of a split group run once for each
            # part of it, rather than once. This is how they run when running
            # only part of a group with `rspec path/to/spec.rb:42`, so it is
            # safe for most suites and lets long groups be spread over workers.
            #
            # Tag a group with `:parallel_split => false` to always run it in a
            # single worker.
            # @return [Boolean]
            configuration.add_setting :parallel_split_groups_with_context_hooks

            configuration.__send__(:attr_writer, :reporter, :parallel_run_times_file_path)

            # @return [Integer, nil] the number of the current parallel worker
            #   (starting at 1), or nil when not running in a parallel worker.
            configuration.__send__(:attr_accessor, :parallel_worker_number)
          end

          # The file in which parallel runs persist the run time of every
          # example, so that the next parallel runs can hand out the longest
          # groups first and spread them over workers. Defaults to
          # `tmp/rspec_parallel_run_times.txt`, or to
          # `example_status_persistence_file_path` when it is set (the run
          # times persisted there are used). Set it to `nil` to not persist
          # run times.
          #
          # @return [String, nil] the file path
          def parallel_run_times_file_path
            return @parallel_run_times_file_path if defined?(@parallel_run_times_file_path)

            DEFAULT_PARALLEL_RUN_TIMES_FILE_PATH unless example_status_persistence_file_path
          end

          # Registers a block to run in each parallel worker process after it
          # is forked, before its `before(:suite)` hooks. The block receives
          # the worker number. Use it to set up per-worker resources, such as
          # connecting to a per-worker database.
          #
          # @example
          #   RSpec.configure do |config|
          #     config.parallel_worker_setup do |worker_number|
          #       SimpleCov.command_name "rspec-#{worker_number}"
          #     end
          #   end
          def parallel_worker_setup(&block)
            parallel_worker_hooks(:setup) << block
          end

          # Registers a block to run in each parallel worker process after its
          # `after(:suite)` hooks, right before the worker exits. The block
          # receives the worker number.
          def parallel_worker_teardown(&block)
            parallel_worker_hooks(:teardown) << block
          end

          # @private
          def parallel_worker_hooks(type)
            (@parallel_worker_hooks ||= { :setup => [], :teardown => [] })[type]
          end
        end

        # @private
        module ConfigurationOverrides
          # Loading this gem means running in parallel: one worker per physical
          # core unless set (`1` runs the suite sequentially). Where processes
          # can't be forked, the suite runs sequentially without a warning.
          def parallel_workers
            value = super
            return value unless value.nil?

            Parallel.supported? ? Parallel.default_worker_count : 1
          end

        private

          # rspec-core runs the default path (`spec`) when no files are given
          # only when its command is `rspec`.
          def command
            super == 'rspec-parallel' ? 'rspec' : super
          end
        end

        # @private
        module Parser
          def parse(source=nil)
            # The long form of an option with an optional argument consumes the
            # next argument even when it is a file path, the short form does not.
            @original_args = original_args.map { |arg| arg == '--parallel' ? '-j' : arg }
            super
          end

        private

          def parser(options)
            super.tap do |parser|
              parser.separator ''
              parser.separator '  **** Parallel ****'
              parser.separator ''
              parser.on('-j', '--[no-]parallel [COUNT]', Integer,
                        'Run the suite in COUNT forked worker processes (default: number of physical CPU cores).') do |count|
                options[:parallel_workers] = count.nil? ? Parallel.default_worker_count : (count || 1)
              end
            end
          end
        end

        # @private
        module Runner
          def run_specs(example_groups)
            parallel_units = Parallel.units_for(@configuration, @world, example_groups)
            return super unless parallel_units

            examples_count = @world.example_count(example_groups)
            examples_passed = @configuration.reporter.report(examples_count) do |reporter|
              Parallel.run(@configuration, @world, parallel_units, reporter)
            end

            exit_code(examples_passed)
          end
        end

        # @private
        module HookCollections
          # Whether any `before(:context)` or `after(:context)` hook, other than
          # those registered from `globals`, is registered directly on the
          # owner of these hooks.
          def context_hooks?(globals)
            [:before, :after].any? do |position|
              (all_hooks_for(position, :context) - globals.all_hooks_for(position, :context)).any?
            end
          end
        end

        # @private
        module Example
          # Sets the outcome of running this example in another process.
          def restore_exception(exception)
            @exception = exception
          end
        end

        # @private
        module ExampleGroupClassMethods
          # The memoized `let` values of the instance running a split group's
          # `before(:context)` hooks must not be shared with its examples.
          def each_instance_variable_for_example(group)
            super { |ivar| yield ivar unless ivar.to_sym == :@__memoized }
          end
        end

        # @private
        module Reporter
          # Overrides the time profiled for a top-level group, for groups run
          # in another process.
          def record_group_run_time(group, run_time)
            return unless @profiler && @profiler.example_groups.key?(group)

            @profiler.example_groups[group][:total_time] = run_time
          end
        end

        # Order dependencies can only be reproduced in a single process.
        #
        # @private
        module BisectShellCommand
          PARALLEL_OPTION = /\A(-j\d*|--(no-)?parallel(=\d+)?)\z/

          def initialize(original_cli_args)
            super(without_parallel_options(original_cli_args))
          end

          # The bisect runs load this gem, so that a `--parallel` in `.rspec`
          # is a known option there too.
          def command_for(locations, server)
            executable = open3_safe_escape(RSpec::Core.path_to_executable)
            "#{super.sub(executable) { "-rrspec/core/parallel #{executable}" }} --no-parallel"
          end

        private

          def without_parallel_options(args)
            kept = []
            count_may_follow = false
            args.each do |arg|
              next count_may_follow = false if count_may_follow && arg =~ /\A\d+\z/

              count_may_follow = %w[-j --parallel].include?(arg)
              kept << arg unless arg =~ PARALLEL_OPTION
            end
            kept
          end
        end

        # Order dependencies can only be reproduced in a single process.
        #
        # @private
        module BisectRunDispatcher
          def initialize(runner, channel)
            super
            runner.configuration.force(:parallel_workers => 1)
          end
        end
      end
    end

    Configuration.__send__(:include, Parallel::CoreExt::Configuration)
    Configuration.__send__(:prepend, Parallel::CoreExt::ConfigurationOverrides)
    Parser.__send__(:prepend, Parallel::CoreExt::Parser)
    Runner.__send__(:prepend, Parallel::CoreExt::Runner)
    Hooks::HookCollections.__send__(:include, Parallel::CoreExt::HookCollections)
    Example.__send__(:include, Parallel::CoreExt::Example)
    ExampleGroup.singleton_class.__send__(:prepend, Parallel::CoreExt::ExampleGroupClassMethods)
    Reporter.__send__(:include, Parallel::CoreExt::Reporter)
    Bisect::ShellCommand.__send__(:prepend, Parallel::CoreExt::BisectShellCommand)
    Bisect::ForkRunner::RunDispatcher.__send__(:prepend, Parallel::CoreExt::BisectRunDispatcher)
  end
end
