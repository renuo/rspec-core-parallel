# Changelog

## 0.3.0

* `before(:run)` and `after(:run)` hooks, which run once per run: in the main
  process around the workers in parallel runs, around the `:suite` hooks in
  sequential runs.
* SimpleCov merges the coverage of workers that finished more than its
  `merge_timeout` (10 minutes by default) before the slowest one.

## 0.2.1

* No deprecation warning with SimpleCov 1.x, which renamed
  `enable_for_subprocesses` to `merge_subprocesses`.

## 0.2.0

* SimpleCov collects the coverage of the workers without any configuration.
* `--profile` shows the slowest examples as a share of the time taken by all
  the examples, rather than of the run time, which could exceed 100%.
* README: require the gem in `spec_helper.rb` in Rails apps too, to configure it
  there, and create the test database on CI as usual.

## 0.1.0

* Loading the gem makes `rspec` run the suite in forked worker processes, one
  per physical CPU core (`config.parallel_workers = 1` runs it sequentially).
* `rspec-parallel` command, which also takes `--parallel [COUNT]` (`-j`) and
  `--no-parallel`.
* Extracted from a backport of `rspec --parallel` to rspec-core 3.13. Unlike
  there, run times are saved in `tmp/rspec_parallel_run_times.txt` even when
  `tmp` does not exist yet.
