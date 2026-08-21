defmodule PairingsEngine.Changelog do
  @moduledoc """
  Renders `CHANGELOG.md` (repo root) to HTML once, at compile time — the
  single source both `PairingsEngineWeb.ChangelogLive` (the global
  `/changelog` page) and `PairingsEngineWeb.SettingsChangelogLive` (the
  older tournament-scoped `/t/:id/settings/changelog` page) share, so
  there's exactly one place that reads and converts the file rather than
  two copies drifting apart.

  Read via `@external_resource`, not `:code.priv_dir/1` — `priv/` is the
  one directory guaranteed to ship with an OTP release, but `CHANGELOG.md`
  at the repo root is not, so there's no reliable *runtime* path back to it
  once a release has moved things around. `@external_resource` sidesteps
  that by baking the file's content into the compiled module at build
  time instead. The tradeoff: editing `CHANGELOG.md` needs a rebuild to
  show up, same as every other code change in a compiled release.

  ## On earmark's CVE-2026-48591, and why this app is not exposed

  `mix hex.audit` reports earmark as retired and carrying a MEDIUM stored
  XSS (unescaped HTML attribute values). It stays anyway, deliberately.

  Stored XSS needs attacker-controlled markdown. There is none here: the
  only input is `CHANGELOG.md` from this repo, read at COMPILE time, and
  the result is baked into `@html` as a constant. Nothing user-supplied
  reaches Earmark at runtime, or at all — an attacker who could edit
  `CHANGELOG.md` in the build tree could commit Elixir instead, so the
  markdown renderer would not be the weak link.

  The suggested replacement, MDEx, is a Rust NIF. `.github/workflows/
  binaries.yml` cross-builds Burrito executables for five OS/arch targets
  (macOS x86_64 + aarch64, Linux x86_64 + aarch64, Windows x86_64), and
  every one of them would need a Rust toolchain or a matching precompiled
  NIF. That is a real risk to the release builds, taken on to close a hole
  that cannot be reached.

  What keeps this true is the ONE call site. `changelog_test.exs` fails if
  Earmark is ever called from anywhere else — if that guard trips, this
  analysis is void and the dependency has to be reconsidered rather than
  the test relaxed.
  """

  @changelog_path Path.expand("../../CHANGELOG.md", __DIR__)
  @external_resource @changelog_path

  @html (case File.read(@changelog_path) do
           {:ok, markdown} ->
             case Earmark.as_html(markdown) do
               {:ok, html, _messages} -> html
               {:error, _html, _messages} -> "<p>Could not render the changelog.</p>"
             end

           {:error, _reason} ->
             "<p>CHANGELOG.md was not found at compile time.</p>"
         end)

  @doc "CHANGELOG.md, pre-rendered to HTML at compile time."
  def html, do: @html
end
