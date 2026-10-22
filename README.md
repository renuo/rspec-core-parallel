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

And require it at the top of `spec_helper.rb`. Rails apps also load it with the rest of the `test` group, but only
when the app boots, which is usually after `spec_helper.rb` is loaded: until then, settings like `parallel_workers`
and `parallel_worker_setup` don't exist.

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
`ActiveSupport.parallelize_test_databases = false` to opt out. The main process still uses the test database itself
(`maintain_test_schema!` runs before the workers are forked), so on CI create it as usual, e.g. with
`bin/rails db:create db:schema:load`, rather than with `parallel:create`.

**Logs.** In Rails apps every worker writes to its own log file (`log/test-1.log`, `log/test-2.log`, ...), so that the
lines of the workers don't mix in `log/test.log`, which keeps the lines of the main process.

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

**Hooks.** `before(:suite)`, `after(:suite)` and `at_exit` hooks run in every worker. For what all the workers share,
like starting a service or cleaning it up, use `before(:run)` and `after(:run)`: they run once, in the main process,
before the workers are forked and after they have exited. In sequential runs they run around the `:suite` hooks.

```ruby
RSpec.configure do |config|
  config.before(:run) { TestServer.start }
  config.after(:run) { TestServer.stop }
end
```

When a `before(:run)` hook fails, no example runs, but the `after(:run)` hooks still do.

Hooks that clean up a shared directory after each example, like `after(:each) { FileUtils.rm_rf("public/uploads") }`,
delete the files of the examples running in the other workers. Run them in `after(:run)`, or give each worker its own
directory.

**Background threads.** Some libraries start a background thread when the app boots and start it again in forked
processes, like the reporter of Coverband. In the workers it runs alongside the examples and can make them fail
randomly, e.g. with `can't add a new key into hash during iteration`. Don't start them in the test environment, e.g.
with `COVERBAND_DISABLE_AUTO_START=true` for Coverband.

## Code coverage

SimpleCov collects the coverage of the workers without any configuration: the gem turns on SimpleCov's support for
subprocesses and names the results of each worker after its number, so that they replace those of the previous run. If
you already call `SimpleCov.enable_for_subprocesses true`, your `at_fork` configuration is kept.

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
first. You can change the path with `config.parallel_run_times_file_path`. On CI, cache this file between builds: if
`example_status_persistence_file_path` is set (e.g. to `spec/examples.txt`), that is the file to cache, and
`tmp/rspec_parallel_run_times.txt` is not written at all.

Every parallel run starts by telling where its run times come from:

```
Running in 4 parallel workers, using the run times of 694 examples from tmp/rspec_parallel_run_times.txt.
Running in 4 parallel workers, without run times of a previous run (none found in tmp/rspec_parallel_run_times.txt).
```

If CI keeps printing the second line, check that the cached file is the one named there.

## Requirements

- rspec-core 3.13
- Ruby 3.3 or later. On JRuby and Windows, where `Process.fork` isn't available, the suite runs sequentially.

## License

MIT. Most of the code comes from rspec-core, by the RSpec team.
