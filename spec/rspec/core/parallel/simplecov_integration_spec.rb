module RSpec::Core::Parallel
  RSpec.describe SimpleCovIntegration do
    it 'keeps SimpleCov from taking a worker for the process writing the report' do
      simplecov = Module.new do
        def self.final_result_process?
          true
        end
      end
      stub_const("SimpleCov", simplecov)

      SimpleCovIntegration.after_fork

      expect(simplecov.final_result_process?).to be(false)
    end

    it 'does nothing without SimpleCov' do
      hide_const("SimpleCov")

      expect { SimpleCovIntegration.after_fork }.not_to raise_error
    end
  end
end
