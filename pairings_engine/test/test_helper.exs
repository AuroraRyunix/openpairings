# SQLite has a single writer, and Ecto's SQL Sandbox holds that write lock
# for a test's *entire* transaction once it does its first write (WAL keeps
# the lock until COMMIT/ROLLBACK, not just for the duration of one
# statement) — so any two async tests that both write serialize behind each
# other's full runtime, not just behind an individual query. With the
# default max_cases (2x schedulers — 32 on this machine) enough async
# write-heavy tests pile up behind one another that an unlucky one can
# still lose SQLite's (non-FIFO/non-fair) busy-handler retries for the
# whole 15s busy_timeout and fail with "database busy". This isn't a rare
# edge case: max_cases: 4 cut it down but ~1 in 5 full runs still hit it,
# and even max_cases: 2 (i.e. exactly two concurrent writers) still hit it
# at a similar rate — two is enough for one to occasionally starve past
# 15s. max_cases: 1 removed it entirely across 20+ consecutive full-suite
# runs, and since this suite is small (515 tests finishing in ~5s either
# way), fully serializing costs no real wall-clock time here — the
# `async: true` tags stay meaningful for correctness (manual, per-test
# sandbox connections instead of the shared-mode below) even though they no
# longer buy parallelism.
ExUnit.start(max_cases: 1)
Ecto.Adapters.SQL.Sandbox.mode(PairingsEngine.Repo, :manual)
