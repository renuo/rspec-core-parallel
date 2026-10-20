module RSpec
  module Core
    module Parallel
      # Stands in for the reporter inside a worker process: rather than
      # notifying formatters, it forwards every event to the main process.
      #
      # Events are sent in batches, once per example, to keep the main
      # process, which replays the events of every worker, from becoming a
      # bottleneck.
      #
      # Values provided by user code (metadata, notifications) are marshaled
      # on their own, so that one the main process cannot load (for instance
      # of a class defined while running an example) only affects itself.
      #
      # @private
      class WorkerReporter < Reporter
        UNFORWARDED_METADATA_KEYS = [:execution_result, :example_group, :block, :last_run_status].freeze
        MAX_BATCH_SIZE = 200

        def initialize(configuration, registry, channel, control)
          super(configuration)
          @registry = registry
          @channel = channel
          @control = control
          @metadata_baselines = {}.compare_by_identity
          @unit = nil
          @batch = []
        end

        attr_accessor :unit

        def notify(event, notification)
          case notification
          when Notifications::ExampleNotification
            forward_example_event(event, notification.example)
          when Notifications::GroupNotification
            forward_group_event(event, notification.group)
          else
            forward_notification(event, notification)
          end
        end

        # Custom notifications are instances of anonymous classes, which
        # cannot be sent to the main process: their options are sent instead.
        def publish(event, options={})
          return super if RSPEC_NOTIFICATIONS.include?(event)

          post([:publish, @unit, event, options.to_h { |key, value| [key, pack(value)] }])
        end

        def notify_non_example_exception(exception, context_description)
          @configuration.world.non_example_failure = true
          post([:non_example_exception, @unit, ExceptionSerializer.dump(exception), context_description])
        end

        # Sending the start of each example lets the main process report the
        # example that was running if the worker crashes.
        def example_started(example)
          super
          flush
        end

        def example_finished(example)
          super
          poll_control
        end

        def unit_finished(unit, succeeded, run_time)
          post([:unit_done, unit, succeeded, run_time])
          flush
        end

        # Asks the main process to exit with the given status once the run is
        # over, as when `exit` is called while running the suite sequentially.
        def exit_requested(status)
          post([:exit, @unit, status])
        end

        def worker_finished
          post([:bye, nil])
          flush
        end

        # Marshals a value on its own, along with a description of it to
        # report in its place if the main process cannot load it.
        def self.pack(value)
          [Marshal.dump(value), value.inspect]
        rescue Exception # rubocop:disable Lint/RescueException
          [nil, (value.inspect rescue value.class.name)] # rubocop:disable Style/RescueModifier
        end

        # @return the packed value, or `fallback` (by default, the description
        #   of the value) if it cannot be loaded.
        def self.unpack(packed, fallback=packed[1])
          data = packed[0]
          data ? Marshal.load(data) : fallback # rubocop:disable Security/MarshalLoad
        rescue Exception # rubocop:disable Lint/RescueException
          fallback
        end

        def flush
          return if @batch.empty?

          batch = @batch
          @batch = []
          @channel.write(batch)
        end

      private

        def post(message)
          @batch << message
          flush if @batch.size >= MAX_BATCH_SIZE
        end

        def pack(value)
          self.class.pack(value)
        end

        def forward_example_event(event, example)
          index = @registry.example_index(example)
          return forward_unknown_example(event, example) unless index

          post([:example, @unit, event, index, example_payload(event, example)])
        end

        def example_payload(event, example)
          case event
          when :example_started
            @metadata_baselines[example] = metadata_snapshot(example.metadata)
            [nanoseconds(example.execution_result.started_at)]
          when :example_finished
            execution_result_payload(example.execution_result) << metadata_changes(example)
          end
        end

        def execution_result_payload(result)
          [
            nanoseconds(result.started_at),
            result.status,
            ExceptionSerializer.dump(result.exception),
            nanoseconds(result.finished_at),
            result.run_time,
            result.pending_message,
            ExceptionSerializer.dump(result.pending_exception),
            result.pending_fixed
          ]
        end

        def nanoseconds(time)
          time && ((time.to_i * 1_000_000_000) + time.nsec)
        end

        # Hashes and arrays can be changed in place (as rswag does with
        # `example.metadata[:response]`), so their contents are compared too.
        def metadata_snapshot(metadata)
          metadata.each_with_object({}) do |(key, value), snapshot|
            snapshot[key] = [value, contents_of(value)] unless UNFORWARDED_METADATA_KEYS.include?(key)
          end
        end

        def contents_of(value)
          Marshal.dump(value) if value.is_a?(Hash) || value.is_a?(Array)
        rescue TypeError
          nil
        end

        def metadata_changes(example)
          baseline = @metadata_baselines.delete(example) || {}
          changes = nil
          example.metadata.each do |key, value|
            next if UNFORWARDED_METADATA_KEYS.include?(key)

            before, contents = baseline[key]
            next if baseline.key?(key) && before.equal?(value) && contents_of(value) == contents

            (changes ||= {})[key] = pack(value)
          end
          changes
        end

        def forward_unknown_example(event, example)
          return unless event == :example_failed

          message = "Failure in an example unknown to the main process: #{example.full_description}\n" +
                    ExceptionSerializer.safe_message(example.exception || StandardError.new)
          forward_notification(:message, Notifications::MessageNotification.new(message))
        end

        def forward_group_event(event, group)
          index = @registry.group_index(group)
          post([:group, @unit, event, index]) if index
        end

        def forward_notification(event, notification)
          if event == :message
            post([:message, @unit, notification.message.to_s])
          else
            post([:notify, @unit, event, pack(notification)])
          end
        end

        def poll_control
          return unless @control.readable_now?

          command = @control.read
          @configuration.world.wants_to_quit = true if command.nil? || command.first == :quit
        end
      end
    end
  end
end
