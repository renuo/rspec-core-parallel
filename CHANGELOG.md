# Changelog

## 0.1.0

* Loading the gem makes `rspec` run the suite in forked worker processes, one
  per physical CPU core (`config.parallel_workers = 1` runs it sequentially).
* `rspec-parallel` command, which also takes `--parallel [COUNT]` (`-j`) and
  `--no-parallel`.
* Extracted from a backport of `rspec --parallel` to rspec-core 3.13. Unlike
  there, run times are saved in `tmp/rspec_parallel_run_times.txt` even when
  `tmp` does not exist yet.
