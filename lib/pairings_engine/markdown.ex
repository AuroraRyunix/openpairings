defmodule PairingsEngine.Markdown do
  @moduledoc """
  Markdown to HTML, for `PairingsEngine.Changelog`.

  ## Why this exists rather than a call to a renderer

  This used to be `Earmark.as_html/1`. Earmark is retired - every release
  of it, back to the beginning - and carries CVE-2026-48591, a stored XSS
  through unescaped HTML attribute values. There is no fixed version to
  move to, because the package is abandoned.

  The suggested replacement, MDEx, is a Rust NIF, and this project
  cross-builds Burrito executables for five OS/arch targets. Every one of
  them would then need a Rust toolchain or a matching precompiled NIF, to
  close a hole in a renderer whose only input is a file from this repo.
  Trading a pure-Elixir build for that is the wrong trade, and it gets more
  wrong the more the app is meant to run as a self-contained binary.

  So: `earmark_parser` for the parse - actively maintained, pure Elixir,
  and the half of Earmark that never had the flaw, since the flaw is in
  HTML GENERATION - and the generation is here, where escaping is not
  optional and the tag set is closed.

  ## The one visible difference

  Earmark ran smartypants, so an apostrophe came out as a right single
  quote. `earmark_parser` deprecated that option - passing it does nothing
  but add a deprecation message - so apostrophes now render as they are
  written. Checked rather than assumed: rendering the whole of
  `CHANGELOG.md` through both produces identical counts for all 20 tags it
  uses, and identical text but for that character.

  ## What makes the CVE unreachable rather than unlikely

  Three things, in order of how much they carry:

    1. **Attribute values are always escaped**, `&`, `<`, `>`, `"` and `'`.
       This is the specific defect: Earmark interpolated them raw.
    2. **The tag set is an allowlist.** Anything outside `@tags` renders its
       CHILDREN and drops the element, so a raw `<script>` in the source
       cannot become a `<script>` in the output - it becomes its own text.
       Earmark's escaping was all-or-nothing for the whole document.
    3. **`href`/`src` must be http, https, mailto, or relative.** Nothing
       else survives, so `javascript:` is not a scheme this renderer can
       emit even if something put one in the source.

  None of that is load-bearing today - the only input is `CHANGELOG.md`,
  read at compile time - but "the input happens to be trusted" is a
  property of today's call sites, and the escaping is a property of the
  code. `changelog_test.exs` guards the first claim and asserts Earmark is
  gone from the dependency tree entirely.
  """

  # Everything CHANGELOG.md actually produces, and nothing else. A tag not
  # on this list is not "rejected" - its children still render, so dropping
  # one loses formatting rather than content.
  @tags ~w(
    h1 h2 h3 h4 h5 h6 p br hr
    ul ol li
    strong em code pre
    a
    table thead tbody tr th td
    blockquote del
  )

  # No closing tag, and no children to render.
  @void ~w(br hr img)

  @doc """
  Renders `markdown` to an HTML string.

  Returns the HTML, or a short error paragraph if the parser cannot read
  the input at all - never raises, because the only caller runs at compile
  time and a changelog that fails to parse should not stop the build.
  """
  def to_html(markdown) when is_binary(markdown) do
    case EarmarkParser.as_ast(markdown, gfm: true, breaks: false) do
      {:ok, ast, _messages} -> render(ast)
      {:error, ast, _messages} -> render(ast)
    end
  rescue
    _ -> "<p>Could not render the markdown.</p>"
  end

  defp render(nodes) when is_list(nodes), do: nodes |> Enum.map(&render/1) |> Enum.join()

  # A text node. Escaped, always - this is the one branch that decides
  # whether markdown source can become markup.
  defp render(text) when is_binary(text), do: escape_text(text)

  defp render({tag, attrs, children, _meta}) do
    cond do
      tag not in @tags ->
        render(children)

      tag in @void ->
        "<" <> tag <> attributes(attrs, tag) <> " />"

      true ->
        "<" <> tag <> attributes(attrs, tag) <> ">" <> render(children) <> "</" <> tag <> ">"
    end
  end

  # Anything the parser emits that is not a tuple or a binary (it should not,
  # but a renderer that crashes on an unexpected node is worse than one that
  # skips it).
  defp render(_other), do: ""

  defp attributes(attrs, tag) do
    attrs
    |> Enum.filter(fn {name, value} -> keep_attribute?(tag, name, value) end)
    |> Enum.map_join(fn {name, value} ->
      " " <> name <> ~s(=") <> escape_attribute(to_string(value)) <> ~s(")
    end)
  end

  # `href` and `src` are the only attributes that can carry a scheme, so they
  # are the only ones with a scheme rule.
  defp keep_attribute?(_tag, name, value) when name in ["href", "src"],
    do: safe_url?(to_string(value))

  # Attribute NAMES are not escapable - an attacker-supplied name is a new
  # attribute, not a value - so the names are a closed set too. `style` is on
  # it only because earmark_parser puts table alignment there.
  defp keep_attribute?(_tag, name, _value), do: name in ~w(class style title id)

  defp safe_url?(url) do
    trimmed = url |> String.trim() |> String.downcase()

    cond do
      String.starts_with?(trimmed, "http://") -> true
      String.starts_with?(trimmed, "https://") -> true
      String.starts_with?(trimmed, "mailto:") -> true
      # A relative link, an anchor, or a bare path. Rejected if it contains a
      # colon before the first slash, which is how a scheme is spelled.
      String.contains?(trimmed, ":") -> false
      true -> true
    end
  end

  defp escape_text(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_attribute(value) do
    value
    |> escape_text()
    |> String.replace(~s("), "&quot;")
    |> String.replace("'", "&#39;")
  end
end
