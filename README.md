# rspec-core-parallel

Run your RSpec suite on all the cores of your machine. Add the gem and `rspec` runs in parallel, with one worker per
physical CPU core.

The suite is loaded once, then forked into worker processes. Workers pick up the longest groups first and send their
results back to the main process, which prints a single report. Formatters, `--only-failures`, `--profile`,
`--fail-fast`, `--bisect` and the exit code work as in a normal run.

## Installation

```ruby
group :test do
  gem "rspec-core-parallel"
end
```

Rails apps load the gem with the rest of the `test` group. In other projects, require it at the top of
`spec_helper.rb`:

```ruby
require "rspec/core/parallel"
```

Then run `bundle exec rspec` as usual.

## Number of workers

By default you get one worker per physical CPU core. To change it, set `parallel_workers` in `spec_helper.rb`.
`1` turns parallel runs off.

```ruby
RSpec.configure do |config|
  config.parallel_workers = 4
end
```

To choose it on the command line, use `rspec-parallel`. It is `rspec` with the gem loaded before the options are
parsed, so it also accepts `--parallel [COUNT]` (`-j`) and `--no-parallel`. Command line options win over
`config.parallel_workers`.

```
$ bundle exec rspec-parallel --parallel 4
$ bundle exec rspec-parallel --no-parallel spec/models/user_spec.rb
```

## Compared to parallel_tests

[parallel_tests](https://github.com/grosser/parallel_tests) starts one rspec process per CPU and splits the spec files
between them up front. With rspec-core-parallel:

- the app boots once and the workers are forked from it;
- groups are handed out while the suite runs, longest first, based on the previous run, and long files are split, so
  the workers finish at about the same time;
- you get one report and one exit code;
- in Rails apps, the test databases of the workers are created and loaded for you.

## Isolation

Each worker is a separate process, so examples running at the same time never share global state like constants,
stubs or `RSpec.configuration`. Most suites run unchanged. What workers do share are external resources: databases,
files, Redis, and so on.

**Databases.** In Rails apps every worker gets its own test database (`app_test_0`, `app_test_1`, ...), created and
loaded from the schema when needed, like `rails test` does in parallel. Set
`ActiveSupport.parallelize_test_databases = false` to opt out.

**Other resources.** Each worker gets a `TEST_ENV_NUMBER` environment variable (`""`, `"2"`, `"3"`, ...) as with
parallel_tests, and runs the `parallel_worker_setup` hooks. Workers are forked after the suite is loaded, so anything
set up while loading, like a constant with a directory or a Redis client, is the same in all of them. This also applies
to config that reads `TEST_ENV_NUMBER` while the app boots: the variable doesn't exist yet at that point. Point those
resources to a per-worker instance in `parallel_worker_setup` instead. For example, a separate upload directory per
worker:

```ruby
RSpec.configure do |config|
  config.parallel_worker_setup do |worker_number|
    CarrierWave.configure { |c| c.root = Rails.root.join("tmp/uploads/#{worker_number}") }
  end
end
```

**Hooks.** `before(:suite)`, `after(:suite)` and `at_exit` hooks run in every worker.

## Code coverage

SimpleCov needs to collect coverage from the forked workers:

```ruby
SimpleCov.enable_for_subprocesses true
SimpleCov.start

RSpec.configure do |config|
  # Without a stable name, SimpleCov names each worker after its pid, and the results of old runs pile up.
  config.parallel_worker_setup do |worker_number|
    SimpleCov.command_name "RSpec (worker #{worker_number})"
  end
end
```

Workers only save their results. The main process exits last: it merges them, writes the report and checks the
minimum coverage.

## Splitting long groups

A group that would take longer than a worker's share of the suite is split into its child groups and chunks of
examples, which run in different workers. Groups with their own `before(:context)` or `after(:context)` hooks are not
split, because those hooks would run once per chunk. Set `config.parallel_split_groups_with_context_hooks = true` to
split them anyway.

Since examples of the same file can run at the same time, tag groups that use a fixed file or directory (a browser
download folder, for example) with `parallel_split: false`, or give each worker its own path.

## Run times

The run time of each example is saved to `tmp/rspec_parallel_run_times.txt`, or to
`config.example_status_persistence_file_path` if you set one. The next run uses it to start the longest groups
first. You can change the path with `config.parallel_run_times_file_path`. On CI, cache this file between builds.

## Requirements

- rspec-core 3.13
- Ruby 3.3 or later. On JRuby and Windows, where `Process.fork` isn't available, the suite runs sequentially.

## License

MIT. Most of the code comes from rspec-core, by the RSpec team.
