module RSpec
  module Core
    module Parallel
      # Leaves SimpleCov's report to the main process. SimpleCov saves the
      # coverage of every process at exit, and the process it considers the
      # final one merges them, writes the report and checks the minimum
      # coverage. It can't tell the workers from the main process (SimpleCov
      # 1.x even takes the first worker for the final process, because of
      # its `TEST_ENV_NUMBER`), so workers finishing early checked the
      # coverage collected so far and printed false "below minimum coverage"
      # warnings. The main process exits after all the workers.
      #
      # @private
      module SimpleCovIntegration
        # @private
        module NotFinalResultProcess
          def final_result_process?
            false
          end
        end

        def self.after_fork
          return unless defined?(::SimpleCov) && ::SimpleCov.respond_to?(:final_result_process?)

          ::SimpleCov.singleton_class.__send__(:prepend, NotFinalResultProcess)
        end
      end
    end
  end
end
