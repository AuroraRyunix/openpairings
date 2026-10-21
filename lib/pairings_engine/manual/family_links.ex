defmodule PairingsEngine.Manual.FamilyLinks do
  @moduledoc """
  The small text jobs of the family pages (`PairingsEngine.Manual.Family`):

    * `rewrite/4` decides where a link in a vendored document goes: another
      vendored page of the same program becomes an in-help link, anything
      else points at the program's GitHub;
    * `scrub/1` is what `mix help.sync_family` does to a document on its way
      in: pictures it cannot vendor are dropped, and the brand name of the
      electronic boards is written the way this manual writes it;
    * `drop_sections/3` leaves a README's developer sections (tests,
      building, code layout) on GitHub, where the people who want them look.
  """

  @github "https://github.com/teapot-chess"

  @doc "The GitHub address of a program's repository."
  def github(repo), do: "#{@github}/#{repo}"

  @doc "Where a program's releases are listed."
  def releases(repo), do: "#{@github}/#{repo}/releases/latest"

  @doc """
  Rewrites `href`, found in the document whose path inside the program's
  repository is `source` (`"docs/macos.md"`). `pages` maps the repository
  paths of the vendored documents to their help addresses.
  """
  def rewrite(href, source, pages, repo) when is_binary(href) do
    cond do
      href == "" or String.starts_with?(href, "#") -> href
      Regex.match?(~r/\A[a-zA-Z][a-zA-Z0-9+.-]*:/, href) -> href
      String.starts_with?(href, "/") -> href
      true -> relative(href, source, pages, repo)
    end
  end

  defp relative(href, source, pages, repo) do
    {path, anchor} =
      case String.split(href, "#", parts: 2) do
        [path, anchor] -> {path, "#" <> anchor}
        [path] -> {path, ""}
      end

    # A Dutch page sits one folder deeper than the English one it translates.
    base = source |> String.replace("/nl/", "/") |> Path.dirname()
    resolved = normalise(Path.join(base, path))

    case Map.fetch(pages, resolved) do
      {:ok, address} -> address <> anchor
      :error -> github(repo) <> "/blob/main/" <> resolved <> anchor
    end
  end

  # `a/b/../c` -> `a/c`; never climbs out of the repository.
  defp normalise(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.reduce([], fn
      ".", acc -> acc
      "..", [] -> []
      "..", [_ | rest] -> rest
      part, acc -> [part | acc]
    end)
    |> Enum.reverse()
    |> Enum.join("/")
  end

  @doc """
  The sync's clean-up of one document: images are removed (none are
  vendored), a copyright line loses the holder's name, the line endings are
  `\\n`, and the brand name of the
  electronic boards, `DGT`, becomes "electronic boards" in prose (code
  spans, code blocks and link targets are left alone).
  """
  def scrub(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> drop_images()
    |> drop_copyright_holder()
    |> map_prose(&Regex.replace(~r/\bDGT\b/, &1, "electronic boards"))
  end

  # `(c) 2026 Some Person - the same licence` -> `the same licence`, and
  # `, © 2026 Some Person.` -> `.`: the manual names no people.
  defp drop_copyright_holder(text) do
    text
    |> then(&Regex.replace(~r/\(c\) \d{4} [^\n-]+ - /, &1, ""))
    |> then(&Regex.replace(~r/,? ?(?:©|\([cC]\)) \d{4} [^\n.,;()-]+/u, &1, ""))
  end

  defp drop_images(text) do
    text
    |> then(&Regex.replace(~r/!\[[^\]]*\]\([^)]*\)/, &1, ""))
    # A link that only wrapped a picture is now `[](...)`.
    |> then(&Regex.replace(~r/\[\s*\]\([^)]*\)/, &1, ""))
    |> then(&Regex.replace(~r/\n{3,}/, &1, "\n\n"))
  end

  @doc """
  Leaves out the sections of `text` whose heading is one of `headings`
  (the heading's text as written, without `#` marks or a `{#id}`): from
  that heading to the next one of the same or a higher level. This is how
  a README's "Tests" and "Building" stay on GitHub, where developers look,
  instead of in a manual for arbiters.

  A link elsewhere in the document to a section that went (`(#where)`)
  would land nowhere in the help, so it is pointed at `source_url`, the
  document on GitHub, instead. Headings inside code blocks are code.
  """
  def drop_sections(text, [], _source_url) when is_binary(text), do: text

  def drop_sections(text, headings, source_url) when is_binary(text) do
    wanted = MapSet.new(headings)

    {kept, dropped_ids, _} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], [], %{fence?: false, dropping: nil}}, fn line, {kept, ids, st} ->
        heading = if st.fence?, do: nil, else: heading(line)
        st = if fence?(line), do: %{st | fence?: not st.fence?}, else: st

        # A heading at or above the level being dropped ends the drop; it
        # may start the next one.
        st =
          if heading && st.dropping && elem(heading, 0) <= st.dropping,
            do: %{st | dropping: nil},
            else: st

        cond do
          heading && st.dropping == nil && MapSet.member?(wanted, elem(heading, 1)) ->
            {kept, [elem(heading, 2) | ids], %{st | dropping: elem(heading, 0)}}

          heading && st.dropping ->
            {kept, [elem(heading, 2) | ids], st}

          st.dropping ->
            {kept, ids, st}

          true ->
            {[line | kept], ids, st}
        end
      end)

    text = kept |> Enum.reverse() |> Enum.join("\n")

    Enum.reduce(dropped_ids, text, fn id, acc ->
      String.replace(acc, "](##{id})", "](#{source_url}##{id})")
    end)
  end

  defp fence?(line), do: Regex.match?(~r/\A\s*(```|~~~)/, line)

  # `{level, text, id}` of a `##`-style heading line, or nil.
  defp heading(line) do
    case Regex.run(~r/\A(\#{1,6})\s+(.*?)\s*\#*\s*\z/, line) do
      [_, hashes, rest] ->
        {text, id} =
          case Regex.run(~r/\A(.*?)\s*\{#([A-Za-z0-9_-]+)\}\z/, rest) do
            [_, text, id] -> {text, id}
            nil -> {rest, PairingsEngine.Manual.Markup.heading_id(rest)}
          end

        {String.length(hashes), text, id}

      nil ->
        nil
    end
  end

  # Applies `fun` to the prose only: fenced blocks and inline code are kept.
  defp map_prose(text, fun) do
    text
    |> String.split("\n")
    |> Enum.map_reduce(false, fn line, in_fence? ->
      cond do
        Regex.match?(~r/\A\s*(```|~~~)/, line) -> {line, not in_fence?}
        in_fence? -> {line, in_fence?}
        true -> {prose_line(line, fun), in_fence?}
      end
    end)
    |> elem(0)
    |> Enum.join("\n")
  end

  defp prose_line(line, fun) do
    ~r/(`+)(?:.*?)\1|\]\([^)]*\)/
    |> Regex.split(line, include_captures: true)
    |> Enum.map_join(fn piece ->
      if String.starts_with?(piece, "`") or String.starts_with?(piece, "]("),
        do: piece,
        else: fun.(piece)
    end)
  end
end
