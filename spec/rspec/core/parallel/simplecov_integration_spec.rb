require 'coverage'

module RSpec::Core::Parallel
  RSpec.describe SimpleCovIntegration do
    let(:simplecov) do
      Module.new do
        class << self
          attr_accessor :enabled_for_subprocesses

          def enable_for_subprocesses(value)
            self.enabled_for_subprocesses = value
          end

          def enabled_for_subprocesses?
            enabled_for_subprocesses
          end

          def command_name(name=nil)
            @command_name = name if name
            @command_name
          end

          def final_result_process?
            true
          end
        end
      end
    end

    before do
      stub_const("SimpleCov", simplecov)
      simplecov.command_name 'RSpec'
      allow(::Coverage).to receive(:running?).and_return(true)
      allow(SimpleCovIntegration).to receive(:require).with('simplecov/process')
    end

    it 'starts SimpleCov in the workers, named after their number' do
      SimpleCovIntegration.before_fork
      simplecov.command_name 'RSpec (subprocess: 12345)'
      SimpleCovIntegration.after_fork(2)

      expect(simplecov.enabled_for_subprocesses?).to be(true)
      expect(SimpleCovIntegration).to have_received(:require).with('simplecov/process')
      expect(simplecov.command_name).to eq 'RSpec (worker 2)'
    end

    it 'uses the setting of SimpleCov 1.x, which deprecates `enable_for_subprocesses`' do
      simplecov.define_singleton_method(:merge_subprocesses) { |value| self.enabled_for_subprocesses = value }
      allow(simplecov).to receive(:enable_for_subprocesses).and_call_original

      SimpleCovIntegration.before_fork

      expect(simplecov.enabled_for_subprocesses?).to be(true)
      expect(simplecov).not_to have_received(:enable_for_subprocesses)
    end

    it 'keeps the configuration of suites already measuring the coverage of subprocesses' do
      simplecov.enable_for_subprocesses true
      SimpleCovIntegration.before_fork
      simplecov.command_name 'Custom (subprocess: 12345)'
      SimpleCovIntegration.after_fork(2)

      expect(SimpleCovIntegration).not_to have_received(:require)
      expect(simplecov.command_name).to eq 'Custom (subprocess: 12345)'
    end

    it 'does not start SimpleCov in the workers when it is not measuring coverage' do
      allow(::Coverage).to receive(:running?).and_return(false)

      SimpleCovIntegration.before_fork

      expect(simplecov.enabled_for_subprocesses?).to be_falsey
    end

    it 'merges the results of workers that finished long before the others' do
      simplecov.define_singleton_method(:merge_timeout) do |seconds=nil|
        @merge_timeout = seconds if seconds
        @merge_timeout || 600
      end
      allow(::Process).to receive(:clock_gettime).and_return(100.0, 1300.2)

      SimpleCovIntegration.before_fork
      SimpleCovIntegration.after_workers

      expect(simplecov.merge_timeout).to eq 1801
    end

    it 'keeps SimpleCov from taking a worker for the process writing the report' do
      SimpleCovIntegration.after_fork(1)

      expect(simplecov.final_result_process?).to be(false)
    end

    it 'does nothing without SimpleCov' do
      hide_const("SimpleCov")

      expect { SimpleCovIntegration.before_fork }.not_to raise_error
      expect { SimpleCovIntegration.after_fork(1) }.not_to raise_error
    end
  end
end
