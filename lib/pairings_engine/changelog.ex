defmodule PairingsEngine.Changelog do
  @moduledoc """
  Renders `CHANGELOG.md` (repo root) to HTML once, at compile time - the
  single source both `PairingsEngineWeb.ChangelogLive` (the global
  `/changelog` page) and `PairingsEngineWeb.SettingsChangelogLive` (the
  older tournament-scoped `/t/:id/settings/changelog` page) share, so
  there's exactly one place that reads and converts the file rather than
  two copies drifting apart.

  Read via `@external_resource`, not `:code.priv_dir/1` - `priv/` is the
  one directory guaranteed to ship with an OTP release, but `CHANGELOG.md`
  at the repo root is not, so there's no reliable *runtime* path back to it
  once a release has moved things around. `@external_resource` sidesteps
  that by baking the file's content into the compiled module at build
  time instead. The tradeoff: editing `CHANGELOG.md` needs a rebuild to
  show up, same as every other code change in a compiled release.

  ## Earmark's CVE-2026-48591, and why the dependency is gone

  This used to call `Earmark.as_html/1`. `mix hex.audit` reported earmark
  as retired and carrying a MEDIUM stored XSS through unescaped HTML
  attribute values, and the reasoning here used to be that the hole was
  unreachable: the only input is `CHANGELOG.md` from this repo, read at
  COMPILE time, so nothing user-supplied reaches the renderer at all.

  That reasoning was correct and is not why the dependency left. It left
  because EVERY earmark release is retired, so there was no fixed version
  to move to and never will be - an unreachable hole in an abandoned
  package is still a permanent line in every audit, and the next person to
  read that line has to re-derive the whole argument to dismiss it.

  The suggested replacement, MDEx, is a Rust NIF, which
  `.github/workflows/binaries.yml` cannot have: it cross-builds Burrito
  executables for five OS/arch targets, and each would then need a Rust
  toolchain or a matching precompiled NIF. So instead `earmark_parser`
  does the parse - maintained, pure Elixir, and the half that never had
  the flaw, since the flaw is in HTML generation - and
  `PairingsEngine.Markdown` does the generation, with escaping that is not
  optional and a closed tag set. See that module.

  `changelog_test.exs` asserts earmark is absent from the dependency tree
  rather than merely called from one place, which is a check that cannot
  quietly stop being true.
  """

  @changelog_path Path.expand("../../CHANGELOG.md", __DIR__)
  @external_resource @changelog_path

  # Entry tags. The markdown writes them as plain `[Fix]` text so the file
  # still reads on GitHub, and they become coloured pills here.
  #
  # Substituted after rendering rather than written as `<span>` into the
  # markdown: the renderer escapes text and emits only tags on its own
  # allowlist, so a `<span>` in the source would come out as visible
  # characters rather than markup. Doing it here keeps that property - the
  # only markup this step can introduce is these six literals.
  #
  # Inlined rather than called as a private function: this runs while the
  # module is still being compiled, and a module cannot call itself there.
  @tags ~w(Feature Fix Change Removed Security Verified)

  @html (case File.read(@changelog_path) do
           {:ok, markdown} ->
             Enum.reduce(@tags, PairingsEngine.Markdown.to_html(markdown), fn tag, acc ->
               String.replace(
                 acc,
                 "[#{tag}]",
                 ~s(<span class="cl-tag cl-#{String.downcase(tag)}">#{tag}</span>)
               )
             end)

           {:error, _reason} ->
             "<p>CHANGELOG.md was not found at compile time.</p>"
         end)

  @doc "CHANGELOG.md, pre-rendered to HTML at compile time."
  def html, do: @html
end
