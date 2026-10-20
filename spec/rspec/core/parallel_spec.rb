module RSpec::Core
  RSpec.describe Parallel do
    describe ".default_worker_count" do
      before { allow(Etc).to receive(:nprocessors).and_return(8) }

      it "is the number of physical cores" do
        allow(Parallel).to receive(:physical_core_count).and_return(4)
        expect(Parallel.default_worker_count).to eq 4
      end

      it "is limited by the processors the process may use" do
        allow(Parallel).to receive(:physical_core_count).and_return(16)
        expect(Parallel.default_worker_count).to eq 8
      end

      it "is the number of processors when the number of cores is unknown" do
        allow(Parallel).to receive(:physical_core_count).and_return(nil)
        expect(Parallel.default_worker_count).to eq 8
      end
    end

    describe ".physical_core_count" do
      it "counts the cores whose hardware threads Linux lists as siblings" do
        siblings = { "cpu0" => "0,2", "cpu1" => "1,3", "cpu2" => "0,2", "cpu3" => "1,3" }
        paths = siblings.keys.map { |cpu| "/sys/devices/system/cpu/#{cpu}/topology/thread_siblings_list" }
        allow(Dir).to receive(:[]).and_call_original
        allow(Dir).to receive(:[]).with("/sys/devices/system/cpu/cpu[0-9]*/topology/thread_siblings_list").and_return(paths)
        siblings.each do |cpu, list|
          allow(File).to receive(:read).with("/sys/devices/system/cpu/#{cpu}/topology/thread_siblings_list").and_return("#{list}\n")
        end

        expect(Parallel.physical_core_count).to eq 2
      end
    end
  end
end
