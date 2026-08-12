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
