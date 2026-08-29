# SQLite has a single writer, and Ecto's SQL Sandbox holds that write lock
# for a test's *entire* transaction once it does its first write (WAL keeps
# the lock until COMMIT/ROLLBACK, not just for the duration of one
# statement) - so any two async tests that both write serialize behind each
# other's full runtime, not just behind an individual query. With the
# default max_cases (2x schedulers - 32 on this machine) enough async
# write-heavy tests pile up behind one another that an unlucky one can
# still lose SQLite's (non-FIFO/non-fair) busy-handler retries for the
# whole 15s busy_timeout and fail with "database busy". This isn't a rare
# edge case: max_cases: 4 cut it down but ~1 in 5 full runs still hit it,
# and even max_cases: 2 (i.e. exactly two concurrent writers) still hit it
# at a similar rate - two is enough for one to occasionally starve past
# 15s. max_cases: 1 removed it entirely across 20+ consecutive full-suite
# runs, and since this suite is small (515 tests finishing in ~5s either
# way), fully serializing costs no real wall-clock time here - the
# `async: true` tags stay meaningful for correctness (manual, per-test
# sandbox connections instead of the shared-mode below) even though they no
# longer buy parallelism.

# Some tests depend on artifacts this repo doesn't (and, for the .swar
# files, shouldn't) commit to git: two personal-data SWAR fixtures used
# heavily by swar_import_test.exs (test/fixtures/*.swar - gitignored, see
# .gitignore) and the JaVaFo pairing engine jar (priv/javafo/javafo.jar - a
# third-party binary not ours to redistribute, see docs/setup-guide.md's
# "JaVaFo" section for the download link - NOT docs/README.md, which this
# comment used to point at and which has never actually had that link).
# Locally both are present and the full suite runs. Anywhere else (a fresh
# checkout, CI) the dependent tests are excluded instead of failing outright
# - everything else still runs and still catches regressions. Tests are
# tagged `@moduletag :swar_fixture` / `@tag :javafo` at the call sites that
# actually need the missing file.
#
# That exclusion used to be silent: one `IO.puts` line in a CI log nobody
# reads, then the job goes green having never run the JaVaFo pairing path at
# all - the engine was only ever exercised on the maintainer's own laptop.
# It stays silent-ish for a bare local checkout on purpose (`mix test`
# refusing to run at all just because a third-party jar isn't installed yet
# would be worse), but it is now loud everywhere it can be, and fatal in CI
# for anything that is not a known, permanent gap:
#
#   - a GitHub Actions annotation (`::warning::`) and a row in the run's step
#     summary, so the gap shows up on the Checks tab next to the green
#     checkmark instead of only in scrollback nobody opens;
#   - `SKIP_MISSING_ARTIFACTS`, a comma-separated allowlist (env var) of tags
#     PERMITTED to be excluded without failing the build. Unset - the default
#     for every local checkout - means "all of them", i.e. today's forgiving
#     behaviour. CI sets it to `swar_fixture,javafo` (see elixir.yml): the
#     .swar fixtures can never be committed (real personal data, see above),
#     and - per the investigation below - javafo.jar can't be fetched
#     reliably in CI either, so both are permanent, known gaps rather than
#     regressions. `bbppairings` is deliberately NOT in that list: it is
#     vendored for Linux, CI's runner is Linux, so it should never actually
#     be missing there - if it ever is, that's a real regression worth
#     failing the build over immediately, not losing a test to silently.
#
# javafo.jar fetch, investigated and rejected: rrweb.org/javafo/ has no
# `<a href>` (or guessable filename - javafo.jar, JaVaFo.jar, JaVaFo2.zip all
# 404) pointing at an actual .jar or .zip anywhere on the landing page or its
# linked sub-pages (JaVaFo.htm, JaVaFo1.html, the Word-export's own
# JaVaFo_files/filelist.xml were all checked by hand). The site also fronts
# some paths with its own bot-detection - a non-standard HTTP 999 "AW
# Special Error" for a plain `curl` User-Agent with no Referer, which is
# exactly what an unadorned fetch step would send. Even with a URL, a fetch
# that can start failing the moment a WAF heuristic changes, with no action
# possible on this repo's side, is precisely the kind of fragile that fails
# SILENTLY unless it's built to hard-fail the instant the download isn't a
# real jar - and there is no way to prove that reliably against a site this
# repo doesn't control. Loud-but-not-fatal exclusion is the honest answer.
swar_fixtures_present? =
  File.exists?("test/fixtures/c-reeks.swar") and File.exists?("test/fixtures/problemski.swar")

javafo_present? = File.exists?(PairingsEngine.Pairing.javafo_jar())

# bbpPairings is vendored (priv/bbppairings/ - see PairingsEngine.Test.BbpPairings'
# moduledoc) for Linux and Windows, so this only ever excludes anything on an
# OS with no vendored build (currently just macOS) - or a genuine regression
# in the vendored binary itself.
bbppairings_present? = PairingsEngine.Test.BbpPairings.available?()

# How many tests each tag actually gates, for the diagnostics below.
# Computed from the source rather than hand-maintained, so it can't go stale
# the way the "see docs/README.md" pointer above it did (that pointer was
# wrong from the day it was written): a file carrying `@moduletag :TAG`
# gates every `test` in that whole module (ExUnit moduletags can't be
# partially revoked), everything else is a straight count of `@tag :TAG`
# lines, each of which precedes exactly one test.
tagged_test_count = fn tag ->
  escaped = tag |> Atom.to_string() |> Regex.escape()
  moduletag_regex = ~r/^\s*@moduletag :#{escaped}\b/m
  own_tag_regex = ~r/^\s*@tag :#{escaped}\b/m
  test_def_regex = ~r/^\s*test\s+("|@|[a-z])/m

  "test/**/*.exs"
  |> Path.wildcard()
  |> Enum.map(&File.read!/1)
  |> Enum.reduce(0, fn source, total ->
    if Regex.match?(moduletag_regex, source) do
      total + length(Regex.scan(test_def_regex, source))
    else
      total + length(Regex.scan(own_tag_regex, source))
    end
  end)
end

# Which excluded tags are allowed to be missing without failing the build -
# see the big comment above. :all (unset/"all"/"*") is every local checkout,
# forever: `mix test` must keep working the moment someone clones this repo,
# with no jar and no personal fixtures in sight.
lenient_tags =
  case System.get_env("SKIP_MISSING_ARTIFACTS") do
    unset when unset in [nil, "", "all", "*"] -> :all
    csv -> csv |> String.split(",") |> Enum.map(&String.trim/1) |> MapSet.new()
  end

lenient? = fn tag -> lenient_tags == :all or MapSet.member?(lenient_tags, Atom.to_string(tag)) end

candidates = [
  {swar_fixtures_present?, :swar_fixture, "test/fixtures/c-reeks.swar not present"},
  {javafo_present?, :javafo, "#{PairingsEngine.Pairing.javafo_jar()} not present"},
  {bbppairings_present?, :bbppairings, "no vendored bbpPairings binary for this OS"}
]

missing =
  for {present?, tag, reason} <- candidates, not present? do
    {tag, reason, tagged_test_count.(tag)}
  end

if missing != [] do
  github_actions? = System.get_env("GITHUB_ACTIONS") == "true"

  Enum.each(missing, fn {tag, reason, count} ->
    IO.puts("Skipping #{count} test(s) tagged :#{tag} - #{reason}")

    # GitHub parses `::warning::` out of ANY step's stdout and turns it into
    # an annotation on the Checks tab - visible next to the green checkmark,
    # not only in a log nobody opens.
    if github_actions? do
      IO.puts(
        "::warning title=#{count} test(s) skipped (:#{tag})::#{reason}. See test/test_helper.exs."
      )
    end
  end)

  case System.get_env("GITHUB_STEP_SUMMARY") do
    nil ->
      :ok

    path ->
      table =
        [
          "### Tests excluded from this run",
          "",
          "| tag | tests | why |",
          "| --- | ---: | --- |"
        ] ++ for {tag, reason, count} <- missing, do: "| `:#{tag}` | #{count} | #{reason} |"

      File.write!(path, "\n" <> Enum.join(table, "\n") <> "\n", [:append])
  end

  strict = for {tag, reason, count} <- missing, not lenient?.(tag), do: {tag, reason, count}

  if strict != [] do
    lines = for {tag, reason, count} <- strict, do: "  :#{tag} (#{count} test(s)) - #{reason}"

    Mix.raise("""
    Refusing to silently exclude tests SKIP_MISSING_ARTIFACTS does not cover:

    #{Enum.join(lines, "\n")}

    Either provide the missing artifact(s), or add the tag to
    SKIP_MISSING_ARTIFACTS (comma-separated) if this is a known, permanent gap
    - see the comment at the top of this file.
    """)
  end
end

exclude_tags = for {tag, _reason, _count} <- missing, do: tag

ExUnit.start(max_cases: 1, exclude: exclude_tags)
Ecto.Adapters.SQL.Sandbox.mode(PairingsEngine.Repo, :manual)
