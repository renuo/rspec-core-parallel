require 'rspec/core'
require_relative 'parallel/version'

module RSpec
  module Core
    # Multi-process execution of a spec suite.
    #
    # The suite is loaded once in the main process, then forked into a pool
    # of workers which share the loaded code copy-on-write. Top-level example
    # groups (or parts of long ones) are dispatched dynamically to idle
    # workers, longest first. Workers stream every
    # reporter event back to the main process, which replays it against its
    # own copies of the examples, so formatters, `--only-failures`, profiling
    # and exit codes behave exactly as in a sequential run.
    #
    # Because every worker is a separate process, global state (constants,
    # stubs, `RSpec.configuration`, database connections...) is never shared
    # between concurrently running examples.
    #
    # @private
    module Parallel
      # @return [Array<Scheduler::Unit>, nil] the units of work to run in
      #   parallel, or nil when the groups must run sequentially.
      def self.units_for(configuration, world, example_groups)
        return nil unless configuration.parallel_workers.to_i > 1 && !configuration.dry_run?

        unless supported?
          RSpec.warning "Running specs in parallel requires `Process.fork`, which is not " \
                        "supported here: running them sequentially", :call_site => nil
          return nil
        end

        require_components
        units = Scheduler.new(configuration, world).units(example_groups, configuration.parallel_workers.to_i)
        units if units.size > 1
      end

      # Loaded only for parallel runs.
      def self.require_components
        %w[
          channel exception_serializer rails_integration simplecov_integration registry scheduler worker_reporter
          worker coordinator
        ].each do |file|
          require_relative "parallel/#{file}"
        end
      end

      # Runs the units in forked worker processes.
      #
      # @return [Boolean] whether all examples passed
      def self.run(configuration, world, units, reporter)
        worker_count = [configuration.parallel_workers.to_i, units.size].min
        passed = Coordinator.new(configuration, world, worker_count).run(units, reporter)
        SimpleCovIntegration.after_workers
        persist_run_times(configuration, world)
        passed
      end

      def self.persist_run_times(configuration, world)
        return unless (path = configuration.parallel_run_times_file_path)

        ExampleStatusPersister.persist(world.all_examples, path)
      rescue SystemCallError => e
        RSpec.warning "Could not write example run times to #{path} (configured as " \
                      "`config.parallel_run_times_file_path`) due to a system error: " \
                      "#{e.inspect}.", :call_site => nil
      end

      def self.supported?
        Process.respond_to?(:fork) && RUBY_ENGINE == 'ruby' && !RSpec::Support::OS.windows?
      end

      # One worker per physical core: workers sharing a core through
      # simultaneous multithreading (hyper-threading) mostly slow each other
      # down, using more CPU time and memory for the same wall time.
      def self.default_worker_count
        require 'etc'
        [Etc.nprocessors, physical_core_count].compact.min
      end

      def self.physical_core_count
        siblings = Dir['/sys/devices/system/cpu/cpu[0-9]*/topology/thread_siblings_list']
        return siblings.map { |path| File.read(path).strip }.uniq.size unless siblings.empty?

        return nil unless RbConfig::CONFIG['host_os'] =~ /darwin/

        count = IO.popen(%w[sysctl -n hw.physicalcpu], :err => File::NULL, &:read).to_i
        count if count > 0
      rescue SystemCallError, IOError
        nil
      end
    end
  end
end

require_relative 'parallel/core_ext'
