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

# Some tests depend on artifacts this repo doesn't (and, for the .swar
# files, shouldn't) commit to git: two personal-data SWAR fixtures used
# heavily by swar_import_test.exs (test/fixtures/*.swar — gitignored, see
# .gitignore) and the JaVaFo pairing engine jar (priv/javafo/javafo.jar — a
# third-party binary not ours to redistribute, see docs/README.md for the
# download link). Locally both are present and the full suite runs.
# Anywhere else (a fresh checkout, CI) the dependent tests are excluded
# instead of failing outright — everything else still runs and still
# catches regressions. Tests are tagged `@moduletag :swar_fixture` /
# `@tag :javafo` at the call sites that actually need the missing file.
swar_fixtures_present? =
  File.exists?("test/fixtures/c-reeks.swar") and File.exists?("test/fixtures/problemski.swar")

javafo_present? = File.exists?(PairingsEngine.Pairing.javafo_jar())

# bbpPairings is vendored (priv/bbppairings/ — see PairingsEngine.Test.BbpPairings'
# moduledoc) for Linux and Windows, so this only ever excludes anything on an
# OS with no vendored build (currently just macOS).
bbppairings_present? = PairingsEngine.Test.BbpPairings.available?()

exclude_tags =
  Enum.reduce(
    [
      {swar_fixtures_present?, :swar_fixture,
       "Skipping SWAR-fixture tests: test/fixtures/c-reeks.swar not present"},
      {javafo_present?, :javafo,
       "Skipping JaVaFo-dependent tests: #{PairingsEngine.Pairing.javafo_jar()} not present"},
      {bbppairings_present?, :bbppairings,
       "Skipping bbpPairings-dependent tests: no vendored binary for this OS"}
    ],
    [],
    fn
      {true, _tag, _message}, acc ->
        acc

      {false, tag, message}, acc ->
        IO.puts(message)
        [tag | acc]
    end
  )

ExUnit.start(max_cases: 1, exclude: exclude_tags)
Ecto.Adapters.SQL.Sandbox.mode(PairingsEngine.Repo, :manual)
