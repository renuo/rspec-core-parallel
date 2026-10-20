module RSpec
  module Core
    module Parallel
      # Splits the suite into units of work and orders them longest first, so
      # that the longest units do not end up running alone at the end of the
      # run. Durations come from the run times stored in
      # `example_status_persistence_file_path` and
      # `parallel_run_times_file_path`; examples without a stored run time are
      # assumed to take the average time of those with one.
      #
      # A unit is usually a whole top-level group. A group expected to take
      # longer than a worker's share of the suite is split into its child
      # groups and parts of its own examples, unless it is tagged with
      # `:parallel_split => false` or has `before(:context)` or
      # `after(:context)` hooks other than global ones (see
      # `Configuration#parallel_split_groups_with_context_hooks`). The units
      # of a split group are kept adjacent so that its output stays together.
      #
      # @private
      class Scheduler
        # @!attribute group
        #   @return [Class] the group to run
        # @!attribute examples_only
        #   @return [Boolean] whether to run only the group's own examples,
        #     and not its child groups
        # @!attribute split_ancestors
        #   @return [Array<Class>] the split groups containing `group`,
        #     outermost first
        # @!attribute examples
        #   @return [Array<Example>, nil] the examples to run when running
        #     only some of the group's own examples
        # @!attribute sequence
        #   @return [Integer] the position of the unit among the parts of its
        #     top-level group when running them sequentially
        Unit = Struct.new(:group, :examples_only, :split_ancestors, :estimate, :examples, :sequence)

        def initialize(configuration, world)
          @configuration = configuration
          @world = world
        end

        # Without run times from a previous run, the duration of groups is
        # unknown: they are split into smaller parts, so that a long one does
        # not end up running alone at the end of the run.
        UNKNOWN_DURATIONS_SPLIT_FACTOR = 16

        # @return [Array<Unit>] the units to run, longest first
        def units(example_groups, worker_count)
          top_level_units = example_groups.filter_map do |group|
            examples = examples_of(group)
            Unit.new(group, false, [], estimated_duration(examples)) unless examples.empty?
          end
          target = top_level_units.sum(&:estimate) / worker_count
          target /= UNKNOWN_DURATIONS_SPLIT_FACTOR if run_times.empty?

          families = top_level_units.map do |unit|
            family = split(unit, target)
            family.each_with_index { |part, sequence| part.sequence = sequence }
            family.each_with_index.sort_by { |part, sequence| [-part.estimate, sequence] }.map(&:first)
          end
          sort_longest_first(families).flatten
        end

        DURATION_UNITS = { 'second' => 1, 'minute' => 60 }.freeze

        # Parses durations formatted by `Formatters::Helpers.format_duration`.
        def self.parse_duration(text)
          parts = text.to_s.scan(/([\d.]+) (second|minute)s?/)
          return nil if parts.empty?

          parts.inject(0.0) { |total, (amount, unit)| total + (amount.to_f * DURATION_UNITS.fetch(unit)) }
        end

      private

        # @return [Array<Unit>] the parts of the unit, in the order in which
        #   they would run sequentially (with the default ordering)
        def split(unit, target)
          return [unit] unless unit.estimate > target && splittable?(unit.group)

          units = parts_of(unit, target).flat_map { |part| split(part, target) }
          units.size > 1 ? units : [unit]
        end

        def splittable?(group)
          return false if group.metadata[:parallel_split] == false

          @configuration.parallel_split_groups_with_context_hooks? || !group.hooks.context_hooks?(@configuration.hooks)
        end

        def parts_of(unit, target)
          return example_chunks(unit, target) if unit.examples_only

          ancestors = unit.split_ancestors + [unit.group]
          own_examples = @world.filtered_examples[unit.group]
          parts = own_examples.empty? ? [] : [Unit.new(unit.group, true, ancestors, estimated_duration(own_examples))]

          unit.group.children.each do |child|
            examples = examples_of(child)
            parts << Unit.new(child, false, ancestors, estimated_duration(examples)) unless examples.empty?
          end
          parts
        end

        # Cuts the examples of a unit into parts expected to take at most
        # `target` each (unless a single example takes longer).
        def example_chunks(unit, target)
          chunks = []
          (unit.examples || @world.filtered_examples[unit.group]).each do |example|
            run_time = run_time_of(example)
            if chunks.empty? || chunks.last.estimate + run_time > target
              chunks << Unit.new(unit.group, true, unit.split_ancestors, 0.0, [])
            end
            chunks.last.examples << example
            chunks.last.estimate += run_time
          end
          chunks.size > 1 ? chunks : []
        end

        # Families of units run longest first: those with the longest unit,
        # then those taking the longest overall.
        def sort_longest_first(families)
          families.each_with_index.sort_by do |family, position|
            [-family.first.estimate, -family.sum(&:estimate), position]
          end.map(&:first)
        end

        def examples_of(group)
          group.descendants.flat_map { |descendant| @world.filtered_examples[descendant] }
        end

        def estimated_duration(examples)
          examples.inject(0.0) { |total, example| total + run_time_of(example) }
        end

        def run_time_of(example)
          run_times.fetch(example.id, default_run_time)
        end

        def default_run_time
          @default_run_time ||= run_times.empty? ? 1.0 : run_times.values.sum / run_times.size
        end

        def run_times
          @run_times ||= load_run_times
        end

        def load_run_times
          paths = [@configuration.example_status_persistence_file_path, @configuration.parallel_run_times_file_path]
          paths.compact.uniq.each_with_object({}) do |path, times|
            ExampleStatusPersister.load_from(path).each do |example|
              run_time = self.class.parse_duration(example[:run_time])
              times[example[:example_id]] = run_time if run_time
            end
          rescue SystemCallError
            next
          end
        end
      end
    end
  end
end
