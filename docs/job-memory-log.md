# Per-job memory log: which jobs make the worker climb

**Date:** 2026-10-20 · **Status:** built and tested (full suite 2160/0), on branch `job-memory-log` · **Order placement:** none. It only observes and writes a log line. It never stops or slows a job.

## Why

The Railway worker restarts at about 0.5 GB, then climbs in steps and stays at about 1.3–1.4 GB all day. The steps come at about 6 AM (catalog imports), and around 10 AM and 2 PM. Ruby keeps a process at the peak of the heaviest job it has run, so each step means some job set a new peak in that process.

Code reading (Oct 20) points at two jobs that load whole supplier catalogs into memory:
- **`CatalogSearchService#build_catalog_index`:** loads every active product of every supplier on the list, even for a one-row search. The same is true of `TeaserCatalogSearchService`.
- **`ProductMapFillService#products_by_map_id`:** loads every mapped, priced product of a supplier.

Carmin asked to confirm with data before any matching code changes. Restarting processes was the other option, and it treats the symptom.

## What it does

`JobMemoryLog` is included in `ApplicationJob`, so it covers every job:

- **Measuring:** it reads the process's resident memory (`VmRSS` in `/proc/self/status`) before and after the job.
- **Logging:** when a job grows its process by **25 MB or more**, it writes one line:
  `[JobMemory] CatalogSearchJob (default) grew its process 310->640 MB (+330) in 42s, 1 other job(s) running in the process, pid 57`
- **Keeping a daily record:** it appends a row to the cache under `job_memory:<date>`, up to 300 rows a day, kept for 14 days. The production cache is Solid Cache in Postgres, so the rows survive a deploy. Railway's logs don't, because they're tied to one deployment.
- **Otherwise quiet:** no email and no in-app notice.
- **Never in the way:** it does nothing where `/proc` doesn't exist (macOS in development and tests), and a failure to record never fails a job.

**Limit:** the size is the whole process's memory. A job that ran alongside others in the same process (`price_verification,default` has 4 threads) can be charged for their growth too. Each row records how many other jobs were running, so look for jobs that show up repeatedly while running alone.

## How to read it

On production, read the rows with `rails runner` and the runner pattern in the project memory. The script must contain no single quotes:

```ruby
rows = Rails.cache.read("job_memory:2026-10-21") || []
rows.group_by { |r| r["job"] }.map { |job, rs| [job, rs.size, rs.sum { |r| r["after_mb"] - r["before_mb"] }] }
    .sort_by { |_, _, total| -total }.each { |job, n, total| puts "#{job}: #{n} steps, +#{total} MB" }
```

Or search the logs: `railway logs --service worker --since 1d --filter "JobMemory"`. Logs only cover the current deployment.

## Next, once the data is in

Fix the confirmed jobs at the source, without restarting processes:
- **Catalog search:** ask Postgres for a few likely candidates per row (a text-similarity index), and match among those instead of loading whole catalogs.
- **Product map fill:** load only the products that rows on the list point to.

Matching changes affect what chefs see, so each needs a before-and-after comparison of match results.

## Tests

`spec/jobs/job_memory_log_spec.rb`:
- logs and records growth of 25 MB or more
- stays quiet for small growth
- records a job that raises
- reads `VmRSS`
- does nothing without `/proc`
- never fails a job when recording fails
- caps each day's rows
