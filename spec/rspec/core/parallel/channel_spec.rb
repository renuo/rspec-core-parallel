
module RSpec::Core::Parallel
  RSpec.describe Channel do
    let!(:channels) { Channel.pipe }
    let(:reader) { channels.first }
    let(:writer) { channels.last }

    after do
      reader.close
      writer.close
    end

    it 'sends messages in order' do
      writer.write([:first, 1])
      writer.write([:second, { :a => "b" }])

      expect(reader.read).to eq([:first, 1])
      expect(reader.read).to eq([:second, { :a => "b" }])
    end

    it 'sends binary data' do
      data = "\xFF\x00café".dup.force_encoding(Encoding::BINARY)
      writer.write(data)

      expect(reader.read).to eq(data)
    end

    it 'reports whether a message can be read without blocking' do
      expect(reader.readable_now?).to be false
      writer.write(:hello)
      expect(reader.readable_now?).to be true
    end

    it 'returns nil once the writing end is closed' do
      writer.close
      expect(reader.read).to be_nil
    end

    it 'sends messages from a child process', :unless => RSpec::Support::OS.windows? || RSpec::Support::Ruby.jruby? do
      pid = Process.fork do
        reader.close
        writer.write([:from_child, "x" * 100_000])
        exit!(0)
      end
      writer.close

      expect(reader.read).to eq([:from_child, "x" * 100_000])
      Process.wait(pid)
    end
  end
end
