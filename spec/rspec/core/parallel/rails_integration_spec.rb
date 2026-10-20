require 'logger'

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
    describe 'log files', :isolated_directory do
      def rails_log
        file = File.open('test.log', 'a')
        file.sync = true
        Logger.new(file)
      end
      it 'gives every worker its own log file next to the one of the app' do
        logger = rails_log
        stub_const("Rails", double(:logger => logger))
        logger.info('before forking')
        RailsIntegration.after_fork(2)
        logger.info("in worker 2 ä")
        expect(File.read('test.log')).to include('before forking')
        expect(File.read('test.log')).not_to include('in worker 2')
        expect(File.read('test-2.log')).to include("in worker 2 ä")
      end
      it 'reopens every logger of a broadcast' do
        loggers = [rails_log, rails_log]
        stub_const("Rails", double(:logger => double(:broadcasts => loggers)))
        RailsIntegration.after_fork(3)
        loggers.each_with_index { |logger, index| logger.info("logger #{index}") }
        expect(File.read('test-3.log')).to include('logger 0', 'logger 1')
        expect(File.read('test.log')).to be_empty
      end
      it 'leaves loggers that do not write to a file as they are' do
        logger = Logger.new(StringIO.new)
        stub_const("Rails", double(:logger => logger))
        RailsIntegration.after_fork(1)
        logger.info('in worker 1')
        expect(logger.instance_variable_get(:@logdev).dev.string).to include('in worker 1')
        expect(Dir.children('.')).to be_empty
      end
    end
  end
end
