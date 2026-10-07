defmodule PairingsEngine.Manual do
  @moduledoc """
  The user manual, rendered once at compile time from `priv/manual/*.md` -
  the single source `PairingsEngineWeb.HelpLive` (`/help`) shows. The files
  are the manual: there is no second copy anywhere (a developer reads them
  on GitHub, an arbiter in the app).

  ## Where the files live, and why

  `priv/` is the one directory every OTP release ships, and `docs/` is
  developer material that a release does not carry. The text is baked into
  the compiled module the way `PairingsEngine.Changelog` bakes in
  `CHANGELOG.md` (`@external_resource` per file), so there is no runtime
  path to lose when a release moves things around. The cost is the same as
  there: editing a chapter needs a rebuild to show up. Adding or removing a
  chapter file is noticed too (`__mix_recompile__?/0`).

  ## Chapter files

  `NN-slug.md`: `NN` sets the order and is the chapter's number, `slug` is
  the address (`/help/slug`). The first `# ` heading is the chapter's title.
  What a chapter may contain beyond plain Markdown (callouts, steps,
  keyboard keys, screenshots, links between chapters) is documented in
  `PairingsEngine.Manual.Markup`, which does the rendering.

  ## What the renderer allows

  `PairingsEngine.Markdown`: a closed tag set, escaped text, safe link
  schemes. Raw HTML in a chapter is shown as text, not run (`<kbd>` aside,
  which the Markup turns into a node of its own).
  """

  @manual_dir Path.expand("../../priv/manual", __DIR__)
  @screenshot_dir Path.expand("../../priv/static/images/manual", __DIR__)

  # `NN-slug.md` only: `SCREENSHOTS.md` beside the chapters is the list of
  # screenshot slots, for whoever takes them, not a chapter.
  list_files = fn dir ->
    dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.filter(&Regex.match?(~r/\A\d+-[a-z0-9-]+\.md\z/, Path.basename(&1)))
    |> Enum.sort()
  end

  list_screenshots = fn dir -> dir |> Path.join("*") |> Path.wildcard() |> Enum.sort() end

  @files list_files.(@manual_dir)
  @files_hash :erlang.md5(:erlang.term_to_binary({@files, list_screenshots.(@screenshot_dir)}))

  for file <- @files, do: @external_resource(file)

  # A chapter added or removed, or a screenshot dropped into
  # `priv/static/images/manual/` (its figure stops being a placeholder).
  @doc false
  def __mix_recompile__? do
    files =
      @manual_dir
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.filter(&Regex.match?(~r/\A\d+-[a-z0-9-]+\.md\z/, Path.basename(&1)))
      |> Enum.sort()

    screenshots = @screenshot_dir |> Path.join("*") |> Path.wildcard() |> Enum.sort()
    :erlang.md5(:erlang.term_to_binary({files, screenshots})) != @files_hash
  end

  @chapters (for {file, index} <- Enum.with_index(@files, 1) do
               base = Path.basename(file, ".md")
               slug = Regex.replace(~r/^\d+-/, base, "")

               rendered =
                 file
                 |> File.read!()
                 |> PairingsEngine.Manual.Markup.chapter(index, screenshot_dir: @screenshot_dir)

               rendered
               |> Map.put(:slug, slug)
               |> Map.put(:number, index)
               |> Map.put(:title, if(rendered.title == "", do: slug, else: rendered.title))
             end)

  @doc """
  Every chapter, in reading order: `%{slug:, number:, title:, summary:, html:,
  toc:, sections:, figures:}` (see `PairingsEngine.Manual.Markup.chapter/3`).
  """
  def chapters, do: @chapters

  @doc "The chapter with this slug, or `nil`."
  def get(slug) when is_binary(slug), do: Enum.find(@chapters, &(&1.slug == slug))
  def get(_), do: nil

  @doc "The slugs, in reading order."
  def slugs, do: Enum.map(@chapters, & &1.slug)

  @doc "The `##` and `###` headings of a chapter, as `%{id:, text:, level:}`."
  def toc(%{toc: toc}), do: toc

  @doc "Every screenshot slot, as `{chapter, figure}`."
  def figures, do: for(c <- @chapters, f <- c.figures, do: {c, f})

  @doc "The chapter before and after `slug`, as `{previous, next}` (each may be `nil`)."
  def neighbours(slug) do
    index = Enum.find_index(@chapters, &(&1.slug == slug))

    if index do
      {if(index > 0, do: Enum.at(@chapters, index - 1)), Enum.at(@chapters, index + 1)}
    else
      {nil, nil}
    end
  end

  @doc """
  Searches the whole manual for `query`: every word of it (case-insensitive)
  must occur in a section's heading or text. Best first: a match in the
  heading outranks one in the text, and more occurrences outrank fewer.

  Returns up to `limit` results, `%{chapter:, section_id:, heading:,
  heading_parts:, snippet_parts:}`. The `_parts` lists are `{text, matched?}`
  pieces, so the page can mark the matches without building HTML here.
  """
  def search(query, limit \\ 30) when is_binary(query) do
    terms =
      query
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)
      |> Enum.filter(&(String.length(&1) >= 2))
      |> Enum.uniq()

    if terms == [] do
      []
    else
      for chapter <- @chapters,
          section <- chapter.sections,
          heading = section.heading || chapter.title,
          haystack = String.downcase(heading <> " " <> section.text),
          Enum.all?(terms, &String.contains?(haystack, &1)) do
        heading_down = String.downcase(heading)

        score =
          Enum.reduce(terms, 0, fn term, acc ->
            acc + if(String.contains?(heading_down, term), do: 20, else: 0) +
              min(occurrences(haystack, term), 10)
          end)

        %{
          chapter: chapter,
          section_id: section.id,
          heading: heading,
          heading_parts: highlight(heading, terms),
          snippet_parts: highlight(snippet(section.text, terms), terms),
          score: score
        }
      end
      |> Enum.sort_by(&{-&1.score, &1.chapter.number})
      |> Enum.take(limit)
    end
  end

  defp occurrences(haystack, term), do: length(String.split(haystack, term)) - 1

  # About 180 characters of the section around its first match.
  defp snippet(text, terms) do
    down = String.downcase(text)

    first =
      terms
      |> Enum.map(fn term ->
        case :binary.match(down, term) do
          {at, _} -> at
          :nomatch -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> 0 end)

    # Byte offsets from :binary.match; step back to a character boundary
    # by slicing on characters from the prefix's length.
    start_char = down |> binary_part(0, first) |> String.length() |> Kernel.-(60) |> max(0)
    piece = String.slice(text, start_char, 180)

    # Start and end on whole words.
    piece =
      if start_char > 0, do: piece |> String.split(" ", parts: 2) |> List.last(), else: piece

    piece =
      if start_char + 180 < String.length(text),
        do: piece |> String.split(" ") |> Enum.drop(-1) |> Enum.join(" "),
        else: piece

    prefix = if start_char > 0, do: "... ", else: ""
    suffix = if start_char + 180 < String.length(text), do: " ...", else: ""
    prefix <> String.trim(piece) <> suffix
  end

  defp highlight(text, terms) do
    pattern =
      terms
      |> Enum.sort_by(&(-String.length(&1)))
      |> Enum.map_join("|", &Regex.escape/1)

    ~r/(#{pattern})/iu
    |> Regex.split(text, include_captures: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn piece -> {piece, Enum.member?(terms, String.downcase(piece))} end)
  end
end
