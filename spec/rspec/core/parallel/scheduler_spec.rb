
module RSpec::Core::Parallel
  RSpec.describe Scheduler do
    include_context "isolated directory"

    around { |example| RSpec::Core::Sandbox.sandboxed { example.run } }

    let(:config) { RSpec.configuration }
    let(:world) { RSpec.world }

    def define_group(name, example_count, &block)
      RSpec.describe(name) do
        example_count.times { |index| it("example #{index}") {} }
        module_exec(&block) if block
      end
    end

    def units_for(groups, worker_count=2)
      Scheduler.new(config, world).units(groups, worker_count)
    end

    def describe_units(units)
      units.map do |unit|
        [unit.group.description, unit.examples_only, unit.split_ancestors.map(&:description)]
      end
    end

    def record_run_times(groups, run_time=1)
      statuses = groups.flat_map(&:descendants).flat_map(&:examples).map do |example|
        { :example_id => example.id, :status => "passed", :run_time => "#{run_time} seconds" }
      end
      File.write("run_times.txt", RSpec::Core::ExampleStatusDumper.dump(statuses))
      config.parallel_run_times_file_path = "run_times.txt"
    end

    it 'orders groups by number of examples when no run times are known' do
      small = define_group("small", 1)
      large = define_group("large", 3)
      medium = define_group("medium", 2)

      expect(units_for([small, large, medium], 1).map(&:group).uniq).to eq([large, medium, small])
    end

    it 'keeps the given order for groups of equal size' do
      groups = Array.new(3) { |index| define_group("group #{index}", 1) }

      expect(units_for(groups).map(&:group)).to eq(groups)
    end

    it 'leaves out groups without examples to run' do
      empty = RSpec.describe("empty")
      group = define_group("group", 1)

      expect(units_for([empty, group]).map(&:group)).to eq([group])
    end

    it 'orders groups by the run times of their examples from the last run' do
      fast = define_group("fast", 3)
      slow = define_group("slow", 1)

      statuses = fast.examples.map { |ex| { :example_id => ex.id, :status => "passed", :run_time => "0.1 seconds" } }
      statuses << { :example_id => slow.examples.first.id, :status => "passed", :run_time => "1 minute 2 seconds" }
      File.write("examples.txt", RSpec::Core::ExampleStatusDumper.dump(statuses))
      config.example_status_persistence_file_path = "examples.txt"

      expect(units_for([fast, slow], 1).map(&:group)).to eq([slow, fast])
    end

    it 'splits groups taking more than the share of a worker into their examples and child groups' do
      large = define_group("large", 2) do
        describe("big child") { 3.times { |index| it("example #{index}") {} } }
        describe("small child") { it("example") {} }
      end
      small = define_group("small", 1)
      record_run_times([large, small])
      units = units_for([large, small])

      expect(describe_units(units)).to eq([
        ["big child", false, ["large"]],
        ["large", true, ["large"]],
        ["small child", false, ["large"]],
        ["small", false, []]
      ])
      expect(units.first(3).sort_by(&:sequence).map { |unit| unit.group.description }).to eq(["large", "big child", "small child"])
    end

    it 'splits child groups recursively' do
      large = define_group("large", 0) do
        describe("child") do
          describe("grandchild 1") { 2.times { |index| it("example #{index}") {} } }
          describe("grandchild 2") { 2.times { |index| it("example #{index}") {} } }
        end
      end
      small = define_group("small", 1)
      record_run_times([large, small])

      expect(describe_units(units_for([large, small]))).to eq([
        ["grandchild 1", false, %w[large child]],
        ["grandchild 2", false, %w[large child]],
        ["small", false, []]
      ])
    end

    it 'does not split groups with context hooks' do
      large = define_group("large", 2) do
        before(:context) {}
        describe("child") { 3.times { |index| it("example #{index}") {} } }
      end
      small = define_group("small", 1)

      expect(describe_units(units_for([large, small]))).to eq([
        ["large", false, []],
        ["small", false, []]
      ])
    end

    it 'splits groups with context hooks when configured to' do
      config.parallel_split_groups_with_context_hooks = true
      large = define_group("large", 0) do
        before(:context) {}
        2.times { |index| describe("child #{index}") { 3.times { |i| it("example #{i}") {} } } }
      end
      small = define_group("small", 1)
      record_run_times([large, small])

      expect(describe_units(units_for([large, small]))).to eq([
        ["child 0", false, ["large"]],
        ["child 1", false, ["large"]],
        ["small", false, []]
      ])
    end

    it 'does not split groups tagged with `:parallel_split => false`' do
      large = RSpec.describe("large", :parallel_split => false) do
        2.times { |index| describe("child #{index}") { 3.times { |i| it("example #{i}") {} } } }
      end
      small = define_group("small", 1)

      expect(describe_units(units_for([large, small]))).to eq([
        ["large", false, []],
        ["small", false, []]
      ])
    end

    it 'does not split groups taking less than the share of a worker' do
      groups = Array.new(2) do |index|
        define_group("group #{index}", 1) { describe("child") { it("example") {} } }
      end
      record_run_times(groups)

      expect(units_for(groups).map(&:group)).to eq(groups)
    end

    it 'splits the examples of a group into consecutive parts' do
      large = define_group("large", 4)
      small = define_group("small", 2)
      record_run_times([large, small])

      units = units_for([large, small])
      expect(describe_units(units)).to eq([
        ["large", true, ["large"]],
        ["large", true, ["large"]],
        ["small", false, []]
      ])
      expect(units.first(2).map(&:examples)).to eq(large.examples.each_slice(3).to_a)
    end

    it 'splits groups into smaller parts when no run times are known' do
      large = define_group("large", 16)
      small = define_group("small", 16)

      expect(units_for([large, small]).map(&:examples)).to eq((large.examples + small.examples).map { |ex| [ex] })
    end

    it 'splits groups having global context hooks' do
      config.before(:context) {}
      large = define_group("large", 0) do
        2.times { |index| describe("child #{index}") { 3.times { |i| it("example #{i}") {} } } }
      end
      small = define_group("small", 1)
      record_run_times([large, small])

      expect(units_for([large, small]).map { |unit| unit.group.description }).to eq(["child 0", "child 1", "small"])
    end

    describe ".parse_duration" do
      it 'parses durations formatted by the formatters' do
        [0.00123, 1, 2.5, 61, 125.3, 400].each do |duration|
          formatted = RSpec::Core::Formatters::Helpers.format_duration(duration)
          expect(Scheduler.parse_duration(formatted)).to be_within(0.6).of(duration)
        end
      end

      it 'returns nil for unparseable values' do
        expect(Scheduler.parse_duration("")).to be_nil
        expect(Scheduler.parse_duration(nil)).to be_nil
      end
    end
  end
end
