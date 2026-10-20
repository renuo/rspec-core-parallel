module RSpec
  module Core
    module Parallel
      # Collects the coverage of the workers with SimpleCov, without any
      # configuration:
      #
      # * turns on SimpleCov's support for subprocesses, which starts SimpleCov
      #   again in every forked worker, and names the results of each worker
      #   after its number, so that they replace those of the previous run.
      #   Suites already enabling it keep their own `at_fork` configuration.
      # * leaves the report to the main process. SimpleCov saves the coverage
      #   of every process at exit, and the process it considers the final one
      #   merges them, writes the report and checks the minimum coverage. It
      #   can't tell the workers from the main process (SimpleCov 1.x even
      #   takes the first worker for the final process, because of its
      #   `TEST_ENV_NUMBER`), so workers finishing early checked the coverage
      #   collected so far and printed false "below minimum coverage"
      #   warnings. The main process exits after all the workers.
      # * extends SimpleCov's `merge_timeout` by the time the workers ran, so
      #   that the main process merges the results of all of them.
      #
      # @private
      module SimpleCovIntegration
        # @private
        module NotFinalResultProcess
          def final_result_process?
            false
          end
        end

        def self.before_fork
          @command_name = nil
          @forked_at = nil
          return unless defined?(::SimpleCov) && defined?(::Coverage.running?) && ::Coverage.running?

          @forked_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
          return if ::SimpleCov.enabled_for_subprocesses?

          @command_name = ::SimpleCov.command_name
          # SimpleCov 1.x renamed `enable_for_subprocesses`, deprecating it.
          if ::SimpleCov.respond_to?(:merge_subprocesses)
            ::SimpleCov.merge_subprocesses true
          else
            ::SimpleCov.enable_for_subprocesses true
          end
          require 'simplecov/process'
        end

        def self.after_fork(worker_number)
          return unless defined?(::SimpleCov) && ::SimpleCov.respond_to?(:final_result_process?)

          ::SimpleCov.command_name "#{@command_name} (worker #{worker_number})" if @command_name
          ::SimpleCov.singleton_class.__send__(:prepend, NotFinalResultProcess)
        end

        # SimpleCov merges only results younger than `merge_timeout`: those of
        # workers finished long before the slowest one would be left out.
        def self.after_workers
          return unless @forked_at && ::SimpleCov.respond_to?(:merge_timeout)

          workers_time = (::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - @forked_at).ceil
          ::SimpleCov.merge_timeout(::SimpleCov.merge_timeout + workers_time)
        end
      end
    end
  end
end
