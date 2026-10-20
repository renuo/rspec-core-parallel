
module RSpec::Core::Parallel
  RSpec.describe ExceptionSerializer do
    def round_trip(exception)
      ExceptionSerializer.load(Marshal.load(Marshal.dump(ExceptionSerializer.dump(exception))))
    end

    def raised(exception, cause=nil)
      raise exception, :cause => cause
    rescue Exception => e # rubocop:disable Lint/RescueException
      e
    end

    it 'returns nil for nil' do
      expect(round_trip(nil)).to be_nil
    end

    it 'preserves the class, message and backtrace of marshalable exceptions' do
      exception = round_trip(raised(ArgumentError.new("bad")))

      expect(exception).to be_an(ArgumentError)
      expect(exception.message).to eq("bad")
      expect(exception.backtrace.first).to include(__FILE__)
    end

    it 'preserves the state of marshalable exceptions' do
      failure = begin
        aggregate_failures do
          expect(1).to eq(2)
          expect(3).to eq(4)
        end
      rescue RSpec::Expectations::MultipleExpectationsNotMetError => e
        e
      end

      exception = round_trip(failure)

      expect(exception).to be_a(RSpec::Expectations::MultipleExpectationsNotMetError)
      expect(exception.all_exceptions.map(&:message)).to eq(failure.all_exceptions.map(&:message))
      expect(exception.message).to eq(failure.message)
    end

    it 'rebuilds unmarshalable exceptions from their class, message, backtrace and cause' do
      unmarshalable = raised(RuntimeError.new("with a proc"), raised(IOError.new("the cause")))
      unmarshalable.instance_variable_set(:@callback, proc {})

      exception = round_trip(unmarshalable)

      expect(exception).to be_a(RuntimeError)
      expect(exception.message).to eq("with a proc")
      expect(exception.backtrace).to eq(unmarshalable.backtrace)
      expect(exception.cause).to be_an(IOError)
      expect(exception.cause.message).to eq("the cause")
    end

    it 'keeps the message of rebuilt exceptions whose class computes it' do
      error_class = Class.new(StandardError) do
        def initialize(callback)
          @callback = callback
          super("unused")
        end

        def message
          "computed: #{@callback.call}"
        end
      end
      stub_const("ComputedMessageError", error_class)

      exception = round_trip(raised(ComputedMessageError.new(proc { 42 })))

      expect(exception).to be_a(ComputedMessageError)
      expect(exception.message).to eq("computed: 42")
    end

    it 'stands in for unmarshalable exceptions whose methods rely on state set by their constructor' do
      error_class = Class.new(StandardError) do
        def initialize(wrapped)
          @wrapped = wrapped
          @callback = proc {}
          super(wrapped.message)
        end

        def backtrace
          @wrapped.backtrace
        end
      end
      stub_const("WrappingError", error_class)

      original = WrappingError.new(raised(IOError.new("wrapped")))
      exception = round_trip(original)

      expect(exception.class.name).to eq("WrappingError")
      expect(exception.message).to eq("wrapped")
      expect(exception.backtrace).to eq(original.backtrace)
    end

    it 'stands in for exceptions whose class is unknown with an exception reporting the original class name' do
      payload = ExceptionSerializer.dump(raised(StandardError.new("oops")))
      payload[:marshaled] = nil
      payload[:class_name] = "Missing::ErrorClass"

      exception = ExceptionSerializer.load(payload)

      expect(exception.class.name).to eq("Missing::ErrorClass")
      expect(exception.message).to eq("oops")
    end
  end
end
