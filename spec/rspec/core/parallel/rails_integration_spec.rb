module RSpec::Core::Parallel
  RSpec.describe RailsIntegration do
    let(:calls) { [] }
    before do
      parallelization = Class.new do
        class << self
          attr_accessor :before_fork_hooks, :after_fork_hooks, :run_cleanup_hooks
        end
      end
      parallelization.before_fork_hooks = [-> { calls << :before_fork }]
      parallelization.after_fork_hooks = [->(worker) { calls << [:after_fork, worker] }]
      parallelization.run_cleanup_hooks = [->(worker) { calls << [:run_cleanup, worker] }]
      stub_const("ActiveSupport::Testing::Parallelization", parallelization)
    end
    it 'runs the hooks Rails provides to parallel test runners, with workers numbered from 0' do
      RailsIntegration.before_fork
      RailsIntegration.after_fork(1)
      RailsIntegration.run_cleanup(3)
      expect(calls).to eq([:before_fork, [:after_fork, 0], [:run_cleanup, 2]])
    end
    it 'loads the translations of Rails apps before forking' do
      stub_const("Rails", double(:application => double))
      stub_const("I18n", Module.new { def self.eager_load!; end })
      allow(I18n).to receive(:eager_load!) { calls << :eager_load }
      RailsIntegration.before_fork
      expect(calls).to eq([:eager_load, :before_fork])
    end
    it 'supports Rails versions without hooks to run before forking' do
      ActiveSupport::Testing::Parallelization.singleton_class.send(:undef_method, :before_fork_hooks)
      RailsIntegration.before_fork
      RailsIntegration.after_fork(1)
      expect(calls).to eq([[:after_fork, 0]])
    end
    it 'does not run the hooks when Rails apps opt out of a database per worker' do
      ActiveSupport.define_singleton_method(:parallelize_test_databases) { false }
      RailsIntegration.before_fork
      RailsIntegration.after_fork(1)
      RailsIntegration.run_cleanup(1)
      expect(calls).to be_empty
    end
    it 'does nothing without Rails' do
      hide_const("ActiveSupport::Testing::Parallelization")
      RailsIntegration.before_fork
      RailsIntegration.after_fork(1)
      expect(calls).to be_empty
    end
  end
end
