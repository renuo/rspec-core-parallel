module RSpec
  module Core
    module Parallel
      # Prepares Rails apps for running in parallel workers, as `rails test`
      # does:
      #
      # * runs the hooks Rails provides to parallel test runners, so that
      #   every worker gets its own test database (named after the
      #   configured one: `app_test_0`, `app_test_1`..., created and loaded
      #   from the schema when needed). Set
      #   `ActiveSupport.parallelize_test_databases` to `false` to opt out.
      #   Workers are numbered from 0 for these hooks, as in Rails. Rails
      #   versions before 8.1 have no hooks to run before forking.
      # * loads the translations before forking, as Rails does when eager
      #   loading, rather than in every worker.
      #
      # @private
      module RailsIntegration
        def self.before_fork
          ::I18n.eager_load! if defined?(::Rails.application) && ::Rails.application && defined?(::I18n.eager_load!)
          hooks(:before_fork_hooks).each(&:call)
        end

        def self.after_fork(worker_number)
          hooks(:after_fork_hooks).each { |hook| hook.call(worker_number - 1) }
        end

        def self.run_cleanup(worker_number)
          hooks(:run_cleanup_hooks).each { |hook| hook.call(worker_number - 1) }
        end

        def self.hooks(type)
          # Loading it registers the hooks creating a database per worker, as
          # `rails/test_help` does.
          require 'active_record/test_databases' if defined?(::ActiveRecord::TestDatabases)
          return [] unless defined?(::ActiveSupport::Testing::Parallelization)
          return [] unless ::ActiveSupport::Testing::Parallelization.respond_to?(type)
          # Rails checks this setting in its hooks only from version 8.1 on.
          return [] if ::ActiveSupport.respond_to?(:parallelize_test_databases) &&
                       ::ActiveSupport.parallelize_test_databases == false

          ::ActiveSupport::Testing::Parallelization.public_send(type)
        rescue LoadError
          []
        end
      end
    end
  end
end
