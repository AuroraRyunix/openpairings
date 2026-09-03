defmodule PairingsEngine.ChangelogTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.Changelog

  test "renders the changelog to HTML at compile time" do
    html = Changelog.html()

    assert html =~ "<h2>"
    refute html =~ "Could not render the changelog"
    refute html =~ "was not found at compile time"
  end

  # earmark is retired - every release of it - and carries CVE-2026-48591,
  # a stored XSS via unescaped HTML attribute values. It was kept for a
  # while on the argument that the only markdown it ever saw was this repo's
  # own CHANGELOG.md at compile time, which was true and is not enough: an
  # abandoned package with a permanent advisory has no version to move to,
  # and every future audit reopens the same argument.
  #
  # It is gone (2026-08-25). `PairingsEngine.Markdown` renders instead, on
  # `earmark_parser` - maintained, pure Elixir, and the half without the
  # flaw. This asserts absence rather than "one call site", because absence
  # cannot quietly stop being true.
  test "earmark is not a dependency at all" do
    refute Code.ensure_loaded?(Earmark),
           "Earmark is back on the load path - see PairingsEngine.Markdown for why it left."

    mix_exs = File.read!("mix.exs")

    refute mix_exs =~ ~r/\{:earmark,/,
           "mix.exs declares :earmark again (\:earmark_parser is the intended one)."
  end

  describe "the renderer, which is ours now" do
    test "escapes text rather than emitting it as markup" do
      html = PairingsEngine.Markdown.to_html(~s|A <script>alert(1)</script> line.|)

      refute html =~ "<script"
      assert html =~ "&lt;script&gt;"
    end

    test "escapes attribute values, which is the exact defect earmark had" do
      html = PairingsEngine.Markdown.to_html(~s|[x](https://e.com/?a=") onload=alert)|)

      # Whatever the parser made of it, the quote may not close the href and
      # let `onload` become an attribute of its own.
      refute html =~ ~s|" onload=|
    end

    test "drops a javascript: link rather than rendering it" do
      html = PairingsEngine.Markdown.to_html("[click](javascript:alert(1))")

      refute html =~ "javascript:"
      # The text survives; only the href is refused.
      assert html =~ "click"
    end

    test "still renders everything the changelog is made of" do
      html =
        PairingsEngine.Markdown.to_html("""
        # Title

        Some **bold** and `code` and a [link](https://example.com).

        - one
        - two

        | a | b |
        |---|---|
        | 1 | 2 |
        """)

      for tag <- ~w(h1 p strong code a ul li table thead tbody tr th td) do
        assert html =~ "<#{tag}", "the renderer stopped emitting <#{tag}>"
      end
    end
  end

  test "no HTML entity survives as its own literal text" do
    # The renderer escapes `&` on purpose - that is what keeps `&lt;script&gt;`
    # inert. The cost is that an entity written in the SOURCE renders as its
    # own name: `&mdash;` reached the page as the six characters "&mdash;",
    # 146 times, on a page anyone can read without an account. Markdown source
    # carries the character itself.
    html = PairingsEngine.Changelog.html()

    refute html =~ ~r/&amp;[a-z]+;/,
           """
           The changelog renders a literal HTML entity. Write the character
           itself in CHANGELOG.md (— → … · ü < >), not its entity name: the
           renderer escapes the ampersand and the reader sees the name.
           """
  end
end
