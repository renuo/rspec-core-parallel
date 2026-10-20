module RSpec
  module Core
    module Parallel
      # A forked process running the units of work it is sent.
      #
      # @private
      class Worker
        attr_reader :number, :pid, :events
        attr_accessor :current_unit, :quit_sent

        def initialize(number)
          @number = number
          @current_unit = nil
          @quit_sent = false
          @alive = true
          @reaped = false
        end

        def alive?
          @alive
        end

        def start(configuration, registry, other_workers)
          @events, events_writer = Channel.pipe
          commands_reader, @commands = Channel.pipe

          # The process exits when the block returns, running `at_exit` hooks
          # (so that tools such as SimpleCov can save their results) but not
          # the `ensure` clauses of the main process's call stack.
          @pid = Process.fork do
            @events.close
            @commands.close
            other_workers.each(&:close)
            run(configuration, registry, commands_reader, events_writer)
          end

          events_writer.close
          commands_reader.close
          self
        end

        def send_command(*command)
          @commands.write(command)
          true
        rescue IOError, SystemCallError
          false
        end

        def close
          @alive = false
          @events.close
          @commands.close
        end

        def exited?
          @reaped ||= !Process.waitpid(@pid, Process::WNOHANG).nil?
        rescue SystemCallError
          @reaped = true
        end

        def wait
          return if @reaped

          Process.waitpid(@pid)
          @reaped = true
        rescue SystemCallError
          @reaped = true
        end

      private

        def run(configuration, registry, commands, events)
          # :nocov: - executed in forked processes, covered by integration specs
          prepare_environment(configuration)
          reporter = WorkerReporter.new(configuration, registry, events, commands)
          configuration.reporter = reporter

          begin
            RailsIntegration.after_fork(@number)
            SimpleCovIntegration.after_fork
            configuration.parallel_worker_hooks(:setup).each { |hook| hook.call(@number) }
            configuration.with_suite_hooks { process_commands(registry, reporter, commands) }
            configuration.parallel_worker_hooks(:teardown).each { |hook| hook.call(@number) }
            RailsIntegration.run_cleanup(@number)
          rescue SystemExit => e
            finish_interrupted_unit(reporter)
            reporter.exit_requested(e.status)
          rescue Exception => e # rubocop:disable Lint/RescueException
            finish_interrupted_unit(reporter)
            reporter.notify_non_example_exception(e, "An error occurred in parallel worker #{@number}.")
          end
          reporter.worker_finished
        rescue IOError, SystemCallError
          # The main process is gone: there is no one left to report to.
          nil
          # :nocov:
        end

        # `PARALLEL_TEST_GROUPS` is not set: with it, SimpleCov assumes it runs
        # under parallel_tests and makes the last worker wait for a parallel_tests
        # pid file. The main process collects the results of all the workers.
        def prepare_environment(configuration)
          ENV['TEST_ENV_NUMBER'] = @number == 1 ? '' : @number.to_s
          configuration.parallel_worker_number = @number
          configuration.world.wants_to_quit = false
          trap_interrupt(configuration.world)
        end

        # The main process tells the user it is shutting down: workers
        # quietly stop after their current example.
        def trap_interrupt(world)
          trap('INT') { world.wants_to_quit ? exit!(1) : world.wants_to_quit = true }
        end

        def process_commands(registry, reporter, commands)
          # Once quitting, groups return without running any example.
          while (command = commands.read) && command.first == :run
            _, unit, group_index, examples_only, ancestor_indices, example_indices = command
            group = registry.groups[group_index]
            ancestors = ancestor_indices.map { |index| registry.groups[index] }
            restrict_examples(group, example_indices.map { |index| registry.examples[index] }) if example_indices
            reporter.unit = unit
            @unit_started_at = RSpec::Core::Time.now
            succeeded = run_unit(group, examples_only, ancestors, reporter)
            reporter.unit = nil
            reporter.unit_finished(unit, succeeded ? true : false, (RSpec::Core::Time.now - @unit_started_at).to_f)
          end
        end

        # Workers are forked processes: the examples of a group can be
        # restricted without affecting the other workers.
        def restrict_examples(group, examples)
          RSpec.world.filtered_examples[group] = examples
        end

        def finish_interrupted_unit(reporter)
          return unless (unit = reporter.unit)

          reporter.unit_finished(unit, false, (RSpec::Core::Time.now - @unit_started_at).to_f)
          reporter.unit = nil
        end

        def run_unit(group, examples_only, ancestors, reporter)
          return run_part(group, examples_only, reporter) if ancestors.empty?

          with_context_hooks_of(ancestors.first, group, examples_only, reporter) do
            run_unit(group, examples_only, ancestors.drop(1), reporter)
          end
        end

        def run_part(group, examples_only, reporter)
          examples_only ? group.run_examples(reporter) : group.run(reporter)
        end

        # Runs the context hooks of a split group around part of it, as
        # `ExampleGroup.run` does around the whole group.
        def with_context_hooks_of(split_group, group, examples_only, reporter)
          return if RSpec.world.wants_to_quit

          begin
            RSpec.current_scope = :before_context_hook
            split_group.run_before_context_hooks(split_group.new('before(:context) hook'))
            yield
          rescue Pending::SkipDeclaredInExample => e
            for_part_examples(group, examples_only, reporter) { |example| example.skip_with_exception(reporter, e) }
            true
          rescue Support::AllExceptionsExceptOnesWeMustNotRescue => e
            for_part_examples(group, examples_only, reporter) { |example| example.fail_with_exception(reporter, e) }
            RSpec.world.wants_to_quit = true if reporter.fail_fast_limit_met?
            false
          ensure
            RSpec.current_scope = :after_context_hook
            split_group.run_after_context_hooks(split_group.new('after(:context) hook'))
          end
        end

        def for_part_examples(group, examples_only, reporter, &block)
          return group.filtered_examples.each(&block) if examples_only

          reporter.example_group_started(group)
          group.for_filtered_examples(reporter, &block)
          reporter.example_group_finished(group)
        end
      end
    end
  end
end
