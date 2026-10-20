module RSpec
  module Core
    module Parallel
      # Carries exceptions raised in a worker over to the main process.
      #
      # Exceptions are Marshal-ed whenever possible so that the main process
      # sees the very same object (class, ivars, cause...). Exceptions holding
      # unmarshalable state (procs, IOs, singleton methods...) or whose class
      # does not exist in the main process are rebuilt from their class name,
      # message, backtrace and cause.
      #
      # @private
      module ExceptionSerializer
        MAX_CAUSE_DEPTH = 10

        # Stands in for exceptions that cannot be reconstructed as instances
        # of their original class.
        class RemoteException < StandardError
          class << self
            attr_accessor :remote_class_name

            def name
              remote_class_name || super
            end
            alias_method :to_s, :name
            alias_method :inspect, :name
          end
        end

        def self.dump(exception, depth=0)
          return nil unless exception

          {
            :marshaled => marshal(exception),
            :class_name => exception.class.name,
            :message => safe_message(exception),
            :backtrace => exception.backtrace,
            :cause => depth < MAX_CAUSE_DEPTH ? dump(exception.cause, depth + 1) : nil
          }
        end

        def self.load(payload)
          return nil unless payload

          unmarshal(payload[:marshaled]) || rebuild(payload)
        end

        def self.marshal(exception)
          Marshal.dump(exception)
        rescue Exception # rubocop:disable Lint/RescueException
          nil
        end

        def self.unmarshal(data)
          return nil unless data

          exception = Marshal.load(data) # rubocop:disable Security/MarshalLoad
          exception if Exception === exception && usable?(exception)
        rescue Exception # rubocop:disable Lint/RescueException
          nil
        end

        def self.safe_message(exception)
          exception.message.to_s
        rescue Exception => e # rubocop:disable Lint/RescueException
          "<#{exception.class.name}#message raised #{e.class}>"
        end

        # Rebuilds the exception as an instance of its class when possible.
        # Classes whose methods rely on state set by their constructor (such
        # as a wrapped exception) get a stand-in reporting their name instead.
        def self.rebuild(payload)
          cause = load(payload[:cause])
          klass = exception_class(payload[:class_name])

          if klass && !klass.method_defined?(:all_exceptions)
            exception = build(klass.allocate, payload, cause)
            return exception if usable?(exception)
          end

          proxy = Class.new(RemoteException)
          proxy.remote_class_name = payload[:class_name]
          build(proxy.allocate, payload, cause)
        end

        def self.build(exception, payload, cause)
          message = payload[:message]
          Exception.instance_method(:initialize).bind_call(exception, message)
          exception.define_singleton_method(:message) { message }
          exception.define_singleton_method(:to_s) { message }
          exception = attach_cause(exception, cause) if cause
          exception.set_backtrace(payload[:backtrace]) if payload[:backtrace]
          exception
        end

        def self.usable?(exception)
          exception.message
          exception.backtrace
          exception.inspect
          true
        rescue Exception # rubocop:disable Lint/RescueException
          false
        end

        def self.exception_class(class_name)
          return nil unless class_name

          klass = Object.const_get(class_name)
          klass if Class === klass && klass <= Exception
        rescue NameError, ArgumentError
          nil
        end

        def self.attach_cause(exception, cause)
          raise exception, :cause => cause
        rescue Exception => e # rubocop:disable Lint/RescueException
          e
        end
      end
    end
  end
end
