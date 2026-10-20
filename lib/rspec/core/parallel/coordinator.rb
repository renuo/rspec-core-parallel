module RSpec
  module Core
    module Parallel
      # Runs in the main process: forks the workers, hands out units of work
      # and replays the events workers send back onto the reporter.
      #
      # Events of one unit are replayed live while events of units running
      # concurrently are buffered and replayed once the live unit finishes,
      # so formatters always see each group as a contiguous whole. The start
      # and finish of groups split into several units are replayed around
      # the events of their units.
      #
      # @private
      class Coordinator
        SELECT_TIMEOUT = 0.5

        def initialize(configuration, world, worker_count)
          @configuration = configuration
          @world = world
          @worker_count = worker_count
        end

        def run(units, reporter)
          @reporter = reporter
          @registry = Registry.new(@world.example_groups)
          @units = units
          @previous_in_family = previous_in_family(units)
          @queue = (0...units.size).to_a
          @results = []
          @run_times = Hash.new(0.0)
          @buffers = {}
          @dispatched_units = {}
          @finished_units = {}
          @replayed_units = {}
          @live_unit = nil
          @open_groups = []
          @orphan_events = []
          @failure_count = 0
          @quitting = false
          @exit_status = nil
          @open_groups_by_unit = Hash.new { |hash, unit| hash[unit] = [] }
          @running_examples = {}

          start_workers
          process_events while @workers.any?(&:alive?)
          finish
          exit(@exit_status) if @exit_status

          @results.all?
        ensure
          terminate_workers
        end

      private

        # @return [Array<Integer, nil>] for each unit, the unit of the same
        #   top-level group running right before it when running sequentially
        def previous_in_family(units)
          previous = []
          families = units.each_index.group_by { |unit| units[unit].split_ancestors.first }
          families.delete(nil)
          families.each_value do |family|
            family.sort_by { |unit| units[unit].sequence }.each_cons(2) { |before, unit| previous[unit] = before }
          end
          previous
        end

        def start_workers
          flush_output_streams
          RailsIntegration.before_fork
          Process.warmup if Process.respond_to?(:warmup)

          @workers = []
          1.upto(@worker_count) do |number|
            worker = Worker.new(number).start(@configuration, @registry, @workers)
            @workers << worker
            dispatch(worker)
          end
        end

        # Output buffered before forking would otherwise be written again by
        # every worker when it exits.
        def flush_output_streams
          ObjectSpace.each_object(IO) do |io|
            begin
              io.flush unless io.closed?
            rescue IOError, SystemCallError
              nil
            end
          end
        end

        def dispatch(worker)
          unit = (@quitting || @world.wants_to_quit) ? nil : @queue.shift

          if unit
            worker.current_unit = unit
            @dispatched_units[unit] = true
            worker.send_command(:run, unit, *unit_location(@units[unit]))
          else
            worker.send_command(:shutdown)
          end
        end

        def unit_location(unit)
          [
            @registry.group_index(unit.group),
            unit.examples_only,
            unit.split_ancestors.map { |group| @registry.group_index(group) },
            unit.examples&.map { |example| @registry.example_index(example) }
          ]
        end

        def process_events
          stop_dispatching if @world.wants_to_quit && !@quitting

          alive = @workers.select(&:alive?)
          ready, = IO.select(alive.map { |worker| worker.events.io }, nil, nil, SELECT_TIMEOUT)
          ready ||= []

          alive.each do |worker|
            if ready.include?(worker.events.io)
              batch = worker.events.read
              batch ? batch.each { |message| handle(worker, message) if worker.alive? } : worker_exited(worker)
            elsif worker.exited?
              # Processes forked by the worker can keep its end of the pipe
              # open after it exited.
              worker_exited(worker)
            end
          end
        end

        def handle(worker, message)
          case message.first
          when :unit_done
            _, unit, succeeded, run_time = message
            worker.current_unit = nil
            @results << succeeded
            @run_times[@units[unit].split_ancestors.first || @units[unit].group] += run_time
            unit_finished(unit)
            dispatch(worker)
          when :exit
            @exit_status ||= message[2]
            stop_dispatching
          when :bye
            worker.close
          else
            track(message)
            count_failure(message)
            route(message)
          end
        end

        # Keeps track of what each unit is running, to clean up after a crash.
        def track(message)
          kind, unit, event, index = message
          return unless unit

          if kind == :group
            event == :example_group_started ? @open_groups_by_unit[unit] << index : @open_groups_by_unit[unit].pop
          elsif kind == :example
            event == :example_started ? @running_examples[unit] = index : @running_examples.delete(unit)
          end
        end

        def worker_exited(worker)
          worker.close
          unit = worker.current_unit
          return unless unit

          worker.current_unit = nil
          @results << false
          report_crash(worker, unit)
          unit_finished(unit)
          stop_dispatching if @exit_status
        end

        # Fails the example that was running, or reports an error outside of
        # examples, and closes the groups the unit left open.
        def report_crash(worker, unit)
          error = ExceptionSerializer.dump(worker_crash_error(worker, unit))

          if (example = @running_examples.delete(unit))
            route([:example, unit, :example_finished, example, [nil, :failed, error, nil, 0.0, nil, nil, nil, nil]])
            route([:example, unit, :example_failed, example, nil])
            @failure_count += 1
          else
            route([:non_example_exception, unit, error, "An error occurred in parallel worker #{worker.number}."])
          end

          (@open_groups_by_unit.delete(unit) || []).reverse_each do |group|
            route([:group, unit, :example_group_finished, group])
          end
        end

        def worker_crash_error(worker, unit)
          group = @units[unit].group
          RuntimeError.new(
            "Parallel worker #{worker.number} (pid #{worker.pid}) exited unexpectedly while running " \
            "`#{group.metadata[:full_description]}` (#{group.location})."
          )
        end

        def count_failure(message)
          return unless message[0] == :example && message[2] == :example_failed

          @failure_count += 1
          stop_dispatching if fail_fast_limit_met?
        end

        def fail_fast_limit_met?
          fail_fast = @configuration.fail_fast
          return false unless fail_fast

          @failure_count >= (fail_fast == true ? 1 : fail_fast)
        end

        def stop_dispatching
          @quitting = true
          @workers.each do |worker|
            next if worker.quit_sent || !worker.alive? || !worker.current_unit

            worker.quit_sent = true
            worker.send_command(:quit)
          end
        end

        def route(message)
          unit = message[1]

          if unit.nil?
            @live_unit || @open_groups.any? ? @orphan_events << message : apply(message)
          else
            make_live(unit) if @live_unit.nil? && replayable_now?(unit)
            unit == @live_unit ? apply(message) : (@buffers[unit] ||= []) << message
          end
        end

        def replayable_now?(unit)
          (@open_groups.empty? || @units[unit].split_ancestors.include?(@open_groups.last)) && next_of_family?(unit)
        end

        # The units of a split group are replayed in their order, as they
        # would run sequentially.
        def next_of_family?(unit)
          previous = @previous_in_family[unit]
          previous.nil? || @replayed_units[previous]
        end

        def started?(unit)
          @finished_units[unit] || @buffers.key?(unit)
        end

        def unit_finished(unit)
          @finished_units[unit] = true
          return unless unit == @live_unit

          @replayed_units[unit] = true
          @live_unit = nil
          replay_next_units
        end

        # Replays buffered units until reaching one that is still running.
        # Units of the innermost open split group come first, so that the
        # group is replayed as a whole before it is closed.
        def replay_next_units
          while @live_unit.nil?
            replay_orphan_events if @open_groups.empty?
            unit = @open_groups.empty? ? next_top_level_unit : unreplayed_units_in(@open_groups.last).first

            if unit.nil?
              break if @open_groups.empty?

              close_group
              next
            end
            break unless started?(unit)

            make_live(unit)
            next unless @finished_units[unit]

            @replayed_units[unit] = true
            @live_unit = nil
          end
        end

        def next_top_level_unit
          candidates = unreplayed_units.select { |unit| next_of_family?(unit) }
          candidates.find { |unit| @finished_units[unit] } || candidates.first
        end

        def replay_orphan_events
          @orphan_events.shift(@orphan_events.size).each { |message| apply(message) }
        end

        def unreplayed_units
          @buffers.keys.reject { |unit| @replayed_units[unit] } +
            @finished_units.keys.reject { |unit| @replayed_units[unit] || @buffers.key?(unit) }
        end

        def unreplayed_units_in(group)
          units = @units.each_index.select do |unit|
            !@replayed_units[unit] && @units[unit].split_ancestors.include?(group)
          end
          units.sort_by { |unit| @units[unit].sequence }
        end

        def make_live(unit)
          ancestors = @units[unit].split_ancestors
          close_group until ancestors[0, @open_groups.size] == @open_groups
          ancestors.drop(@open_groups.size).each do |group|
            @open_groups << group
            @reporter.example_group_started(group)
          end

          @live_unit = unit
          (@buffers.delete(unit) || []).each { |message| apply(message) }
        end

        def close_group
          @reporter.example_group_finished(@open_groups.pop)
        end

        def finish
          # Units never dispatched (after `--fail-fast` or an interrupt) have
          # nothing to replay; replay whatever the others sent.
          @units.each_index do |unit|
            next @finished_units[unit] = true if @dispatched_units[unit]

            @replayed_units[unit] = true
            @results << false
          end
          @live_unit = nil
          replay_next_units
          close_group until @open_groups.empty?
          replay_orphan_events

          @run_times.each { |group, run_time| @reporter.record_group_run_time(group, run_time) }
          @workers.each(&:wait)
        end

        def terminate_workers
          (@workers || []).each do |worker|
            next unless worker.alive?

            worker.close
            begin
              Process.kill(:TERM, worker.pid)
            rescue SystemCallError
              nil
            end
            worker.wait
          end
        end

        def apply(message)
          case message.first
          when :example
            _, _, event, index, payload = message
            example = @registry.examples[index]
            restore(example, payload) if payload
            @reporter.__send__(event, example)
          when :group
            _, _, event, index = message
            @reporter.__send__(event, @registry.groups[index])
          when :message
            @reporter.message(message[2])
          when :notify
            _, _, event, notification = message
            notification = WorkerReporter.unpack(notification, nil)
            @reporter.notify(event, notification) if notification
          when :publish
            _, _, event, options = message
            @reporter.publish(event, options.transform_values { |value| WorkerReporter.unpack(value) })
          when :non_example_exception
            _, _, exception, description = message
            @reporter.notify_non_example_exception(ExceptionSerializer.load(exception), description)
          end
        end

        def time_at(nanoseconds)
          ::Time.at(nanoseconds / 1_000_000_000, nanoseconds % 1_000_000_000, :nsec)
        end

        # Hashes and arrays are updated in place, so that the metadata of groups
        # sharing them with their examples sees the changes, as in the worker.
        # Hashes are merged, to collect the changes of the parts of a group
        # which ran in different workers.
        def restore_metadata(metadata, key, value)
          current = metadata[key]
          if current.frozen? || current.class != value.class || !(Hash === value || Array === value)
            metadata[key] = value
          elsif Hash === value
            merge_in_place(current, value)
          else
            current.replace(value)
          end
        end

        def merge_in_place(target, source)
          source.each do |key, value|
            nested = Hash === target[key] && Hash === value && !target[key].frozen?
            nested ? merge_in_place(target[key], value) : target[key] = value
          end
        end

        def restore(example, payload)
          started_at, status, exception, finished_at, run_time,
            pending_message, pending_exception, pending_fixed, metadata = payload

          result = example.execution_result
          result.started_at = time_at(started_at) if started_at
          return if payload.size == 1

          (metadata || {}).each { |key, value| restore_metadata(example.metadata, key, WorkerReporter.unpack(value)) }
          result.status = status
          result.exception = ExceptionSerializer.load(exception)
          result.finished_at = finished_at && time_at(finished_at)
          result.run_time = run_time
          result.pending_message = pending_message
          result.pending_exception = ExceptionSerializer.load(pending_exception)
          result.pending_fixed = pending_fixed
          example.restore_exception(result.exception)
        end
      end
    end
  end
end
