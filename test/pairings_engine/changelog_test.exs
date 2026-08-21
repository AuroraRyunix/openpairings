defmodule PairingsEngine.ChangelogTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.Changelog

  test "renders the changelog to HTML at compile time" do
    html = Changelog.html()

    assert html =~ "<h2>"
    refute html =~ "Could not render the changelog"
    refute html =~ "was not found at compile time"
  end

  # earmark is retired and carries CVE-2026-48591 (stored XSS via unescaped
  # HTML attribute values). It is kept on purpose, because the only markdown
  # it ever sees is this repo's own CHANGELOG.md, at compile time — see the
  # reasoning in `PairingsEngine.Changelog`'s moduledoc.
  #
  # That reasoning holds only while there is exactly ONE call site. The day
  # someone renders user-supplied markdown — a tournament description, an
  # arbiter's note, an imported file — the CVE becomes live and reachable.
  # This test is the tripwire for that day. If it fails, do not relax it:
  # the dependency has to be replaced, or the new call site sanitised.
  test "Earmark is called from exactly one place, so no user input can reach it" do
    call_sites =
      Path.wildcard("lib/**/*.ex")
      |> Enum.filter(&(File.read!(&1) =~ "Earmark."))

    assert call_sites == ["lib/pairings_engine/changelog.ex"],
           """
           Earmark gained a call site outside the compile-time changelog renderer.

             found: #{inspect(call_sites)}

           CVE-2026-48591 is only unreachable because the sole input is this
           repo's CHANGELOG.md, read at compile time. A new call site may
           feed it user input, which makes the stored-XSS live.
           """
  end
end
