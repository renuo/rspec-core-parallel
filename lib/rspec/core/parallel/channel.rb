module RSpec
  module Core
    module Parallel
      # A one-directional stream of Marshal-encoded, length-prefixed messages.
      #
      # @private
      class Channel
        HEADER_SIZE = 4

        def self.pipe
          reader, writer = IO.pipe
          reader.binmode
          writer.binmode
          writer.sync = true
          [new(reader), new(writer)]
        end

        attr_reader :io

        def initialize(io)
          @io = io
        end

        def write(message)
          data = Marshal.dump(message)
          @io.write([data.bytesize].pack('N') << data)
        end

        # @return [Object, nil] the next message, or nil once the other end is closed.
        def read
          header = read_exactly(HEADER_SIZE)
          return nil unless header

          data = read_exactly(header.unpack1('N'))
          data && Marshal.load(data) # rubocop:disable Security/MarshalLoad
        end

        def readable_now?
          # rubocop:disable-next Lint/IncompatibleIoSelectWithFiberScheduler
          !IO.select([@io], nil, nil, 0).nil?
        end

        def close
          @io.close unless @io.closed?
        end

      private

        def read_exactly(size)
          buffer = @io.read(size)
          buffer if buffer && buffer.bytesize == size
        rescue IOError, SystemCallError
          nil
        end
      end
    end
  end
end
