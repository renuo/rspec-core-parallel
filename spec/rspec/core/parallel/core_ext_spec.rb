module RSpec::Core
  RSpec.describe Parallel::CoreExt do
    describe '--parallel' do
      it 'defaults to the number of physical cores' do
        allow(Parallel).to receive(:default_worker_count).and_return(7)
        expect(Parser.parse(%w[--parallel])[:parallel_workers]).to eq 7
        expect(Parser.parse(%w[-j])[:parallel_workers]).to eq 7
      end

      it 'sets the number of workers' do
        expect(Parser.parse(%w[--parallel 3])[:parallel_workers]).to eq 3
        expect(Parser.parse(%w[--parallel=3])[:parallel_workers]).to eq 3
        expect(Parser.parse(%w[-j3])[:parallel_workers]).to eq 3
        expect(Parser.parse(%w[-j 3])[:parallel_workers]).to eq 3
      end

      it 'does not mistake a following path for the number of workers' do
        allow(Parallel).to receive(:default_worker_count).and_return(7)
        options = Parser.parse(%w[--parallel spec/foo_spec.rb])
        expect(options).to include(:parallel_workers => 7, :files_or_directories_to_run => %w[spec/foo_spec.rb])
      end

      it 'can be turned off' do
        expect(Parser.parse(%w[--no-parallel])[:parallel_workers]).to eq 1
      end

      it 'is applied to the configuration' do
        config = Configuration.new
        ConfigurationOptions.new(%w[--parallel 3]).configure(config)
        expect(config.parallel_workers).to eq 3
      end
    end

    describe 'parallel_workers' do
      let(:config) { Configuration.new }

      it 'defaults to the number of physical cores' do
        allow(Parallel).to receive(:default_worker_count).and_return(7)
        expect(config.parallel_workers).to eq 7
      end

      it 'defaults to 1 where processes cannot be forked' do
        allow(Parallel).to receive(:supported?).and_return(false)
        expect(config.parallel_workers).to eq 1
      end

      it 'can be set to 1 to run the suite sequentially' do
        config.parallel_workers = 1
        expect(config.parallel_workers).to eq 1
      end
    end

    describe 'parallel_run_times_file_path' do
      let(:config) { Configuration.new }

      it 'defaults to a file in tmp' do
        expect(config.parallel_run_times_file_path).to eq 'tmp/rspec_parallel_run_times.txt'
      end

      it 'is the example status persistence file when there is one' do
        config.example_status_persistence_file_path = 'spec/examples.txt'
        expect(config.parallel_run_times_file_path).to be_nil
      end

      it 'can be set, also to nil' do
        config.parallel_run_times_file_path = 'other.txt'
        expect(config.parallel_run_times_file_path).to eq 'other.txt'
        config.parallel_run_times_file_path = nil
        expect(config.parallel_run_times_file_path).to be_nil
      end
    end

    describe 'the rspec-parallel command' do
      it 'runs the default path when no files are given, like rspec' do
        config = Configuration.new
        original = $0
        $0 = '/usr/bin/rspec-parallel'
        config.files_or_directories_to_run = []
        expect(config.instance_variable_get(:@files_or_directories_to_run)).to eq [config.default_path]
      ensure
        $0 = original
      end
    end

    describe 'bisect' do
      let(:server) { double(:drb_port => 1234) }

      it 'runs the bisect commands in a single process' do
        shell_command = Bisect::ShellCommand.new(%w[-j 4 -j3 --parallel --parallel=2 --no-parallel --order defined])
        expect(shell_command.original_cli_args).to eq %w[--order defined]

        command = shell_command.command_for(%w[./foo.rb[1:1]], server)
        expect(command).to include('-rrspec/core/parallel').and end_with('--no-parallel')
      end
    end
  end
end
