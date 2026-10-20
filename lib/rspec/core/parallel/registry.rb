module RSpec
  module Core
    module Parallel
      # Assigns every example group and example a stable index. Workers are
      # forked after the suite is loaded, so walking the same tree yields the
      # same indices in every process, letting processes refer to groups and
      # examples without relying on their ids being unique.
      #
      # @private
      class Registry
        attr_reader :groups, :examples

        def initialize(top_level_groups)
          @groups = []
          @examples = []
          @group_indices = {}.compare_by_identity
          @example_indices = {}.compare_by_identity
          top_level_groups.each { |group| register(group) }
        end

        def group_index(group)
          @group_indices[group]
        end

        def example_index(example)
          @example_indices[example]
        end

      private

        def register(group)
          @group_indices[group] = @groups.size
          @groups << group

          group.examples.each do |example|
            @example_indices[example] = @examples.size
            @examples << example
          end

          group.children.each { |child| register(child) }
        end
      end
    end
  end
end
