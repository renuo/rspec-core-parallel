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
          return unless defined?(::SimpleCov) && defined?(::Coverage.running?) && ::Coverage.running?
          return if ::SimpleCov.enabled_for_subprocesses?

          @command_name = ::SimpleCov.command_name
          ::SimpleCov.enable_for_subprocesses true
          require 'simplecov/process'
        end

        def self.after_fork(worker_number)
          return unless defined?(::SimpleCov) && ::SimpleCov.respond_to?(:final_result_process?)

          ::SimpleCov.command_name "#{@command_name} (worker #{worker_number})" if @command_name
          ::SimpleCov.singleton_class.__send__(:prepend, NotFinalResultProcess)
        end
      end
    end
  end
end
