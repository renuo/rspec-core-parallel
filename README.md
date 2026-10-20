# rspec-core-parallel

Runs an RSpec suite on all the cores of your machine. Add the gem, and `rspec`
runs in parallel, with one worker process per physical CPU core.

RSpec loads the suite once and forks worker processes, which share the loaded
code. Groups are handed out to idle workers, longest first, and every result is
sent back to the main process, which reports them like a sequential run: all
formatters, `--only-failures`, `--profile`, `--fail-fast`, `--bisect` and exit
codes work as usual.

This gem brings `--parallel` to rspec-core 3.13 until it is part of rspec-core
itself.

## Installation

```ruby
group :test do
  gem "rspec-core-parallel"
end
```

Rails apps load it with the other gems of the `test` group. Elsewhere, require
it at the top of `spec_helper.rb`:

```ruby
require "rspec/core/parallel"
```

That's it: `bundle exec rspec` now runs in parallel.

## Number of workers

The default is one worker per physical CPU core. Set it in `spec_helper.rb`
(`1` runs the suite sequentially):

```ruby
RSpec.configure do |config|
  config.parallel_workers = 4
end
```

To choose it on the command line, run `rspec-parallel`, which is `rspec` with
the gem loaded before the options are read, so that it also takes
`--parallel [COUNT]` (`-j`) and `--no-parallel`:

```
$ bundle exec rspec-parallel --parallel 4
$ bundle exec rspec-parallel --no-parallel spec/models/user_spec.rb
```

Options given on the command line win over `config.parallel_workers`.

## How it compares

Unlike [parallel_tests](https://github.com/grosser/parallel_tests) and similar
runners, which start one rspec process per CPU and split the spec files between
them:

* the app boots once, then workers are forked from it;
* groups are dispatched dynamically, longest first (using the run times of the
  previous run), and long files are split, so all the workers finish together;
* there is one combined report, and one exit code;
* in Rails apps, the worker databases are created and loaded by the runner.

## Isolation

Because every worker is a separate process, examples running at the same time
never share global state (constants, stubs, `RSpec.configuration`...), so
existing suites run unchanged, provided that they don't share external
resources such as databases or files between processes.

Rails apps need no setup: as with `rails test` in parallel, every worker gets
its own test database (`app_test_0`, `app_test_1`...), created and loaded from
the schema when needed. Set `ActiveSupport.parallelize_test_databases = false`
to opt out.

Each worker gets a `TEST_ENV_NUMBER` environment variable (`""`, `"2"`, `"3"`...,
as with parallel_tests) and runs `parallel_worker_setup` hooks, which you can
use to give every worker its own resources. Workers are forked once the suite
is loaded, so values computed while loading it, such as a constant holding a
directory or a Redis client, are the same in all of them. This includes
configuration reading `TEST_ENV_NUMBER` while the app boots (as parallel_tests
setups often do for Redis URLs): the variable is only set in the workers, so
such resources must be pointed at a per-worker instance in
`parallel_worker_setup`. For example, to give every worker its own directory
for uploaded files:

```ruby
RSpec.configure do |config|
  config.parallel_worker_setup do |worker_number|
    CarrierWave.configure { |c| c.root = Rails.root.join("tmp/uploads/#{worker_number}") }
  end
end
```

`before(:suite)`, `after(:suite)` and `at_exit` hooks run in every worker.

## Code coverage

To collect code coverage from all the workers with SimpleCov, enable its
support for forked processes:

```ruby
SimpleCov.enable_for_subprocesses true
SimpleCov.start

RSpec.configure do |config|
  # A stable name per worker, so that each run replaces the results of the
  # previous one instead of adding to them (SimpleCov names subprocesses after
  # their pid by default).
  config.parallel_worker_setup do |worker_number|
    SimpleCov.command_name "RSpec (worker #{worker_number})"
  end
end
```

Workers only save their coverage: the main process, which exits last, merges
it, writes the report and checks the minimum coverage.

## Splitting long groups

To spread long groups over several workers, a group expected to take longer
than a worker's share of the suite is split into its child groups and parts of
its examples, unless it has `before(:context)`/`after(:context)` hooks of its
own (which can be allowed with
`config.parallel_split_groups_with_context_hooks = true`) or is tagged with
`:parallel_split => false`. Examples of the same file can therefore run at the
same time in different workers: tag groups whose examples share a file or
directory at a fixed path (such as a browser download directory) with
`:parallel_split => false`, or use a path per worker.

## Run times

The run time of every example is saved in `tmp/rspec_parallel_run_times.txt`,
or in `config.example_status_persistence_file_path` when it is set, so that the
next runs hand out the longest groups first (see
`config.parallel_run_times_file_path`). On CI, cache this file between builds.

## Requirements

* rspec-core 3.13
* Ruby 3.3 or later with `Process.fork`: on JRuby and Windows the suite runs
  sequentially.

## License

MIT. Most of the code comes from rspec-core, by the RSpec team.
