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

  `NN-slug.md`: `NN` sets the order and is never shown, `slug` is the
  address (`/help/slug`). The first `# ` heading is the chapter's title.
  A link to another chapter is written as an ordinary relative link to its
  file (`[Printing](09-printing.md)`), which works on GitHub, and is turned
  into `/help/printing` here. Every `##` and `###` heading gets an `id`
  (its text, lower-cased, runs of other characters becoming one `-`), and `toc/1` lists the `##` headings of a chapter.

  ## What the renderer allows

  `PairingsEngine.Markdown`: a closed tag set, escaped text, safe link
  schemes. Raw HTML in a chapter is shown as text, not run.
  """

  @manual_dir Path.expand("../../priv/manual", __DIR__)
  @files @manual_dir |> Path.join("*.md") |> Path.wildcard() |> Enum.sort()
  @files_hash :erlang.md5(@files)

  for file <- @files, do: @external_resource(file)

  @doc false
  def __mix_recompile__?,
    do:
      :erlang.md5(@manual_dir |> Path.join("*.md") |> Path.wildcard() |> Enum.sort()) !=
        @files_hash

  # Built while the module is still being compiled (the chapter list below
  # is computed then), so these are anonymous functions, not `def`s.
  heading_id_fun = fn text ->
    id =
      text
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if id == "", do: "section", else: id
  end

  # `<h2>Some <code>text</code></h2>` -> the visible text, tags stripped.
  strip_tags = fn html ->
    html |> String.replace(~r/<[^>]*>/, "") |> String.replace("&amp;", "&")
  end

  add_ids = fn html ->
    Regex.replace(~r{<h([23])>(.*?)</h\1>}s, html, fn _all, level, inner ->
      ~s(<h#{level} id="#{heading_id_fun.(strip_tags.(inner))}">#{inner}</h#{level}>)
    end)
  end

  chapter_links = fn html ->
    Regex.replace(~r{href="(?:\d+-)?([a-z0-9-]+)\.md(#[^"]*)?"}, html, fn _all, slug, anchor ->
      ~s(href="/help/#{slug}#{anchor}")
    end)
  end

  @chapters (for file <- @files do
               markdown = File.read!(file)
               base = file |> Path.basename(".md")
               slug = Regex.replace(~r/^\d+-/, base, "")

               title =
                 case Regex.run(~r/^#\s+(.+)$/m, markdown) do
                   [_, t] -> String.trim(t)
                   _ -> slug
                 end

               body =
                 markdown
                 |> PairingsEngine.Markdown.to_html()
                 # The page around it carries the title as its one <h1>.
                 |> String.replace(~r{\A\s*<h1[^>]*>.*?</h1>}s, "")
                 |> add_ids.()
                 |> chapter_links.()

               toc =
                 for [_, inner] <- Regex.scan(~r{<h2[^>]*>(.*?)</h2>}s, body) do
                   text = strip_tags.(inner)
                   %{id: heading_id_fun.(text), text: text}
                 end

               %{slug: slug, title: title, html: body, toc: toc}
             end)

  @doc "Every chapter, in reading order: `%{slug:, title:, html:, toc:}`."
  def chapters, do: @chapters

  @doc "The chapter with this slug, or `nil`."
  def get(slug) when is_binary(slug), do: Enum.find(@chapters, &(&1.slug == slug))
  def get(_), do: nil

  @doc "The slugs, in reading order."
  def slugs, do: Enum.map(@chapters, & &1.slug)

  @doc "The `##` headings of a chapter, as `%{id:, text:}`."
  def toc(%{toc: toc}), do: toc

  @doc "The chapter before and after `slug`, as `{previous, next}` (each may be `nil`)."
  def neighbours(slug) do
    index = Enum.find_index(@chapters, &(&1.slug == slug))

    if index do
      {if(index > 0, do: Enum.at(@chapters, index - 1)), Enum.at(@chapters, index + 1)}
    else
      {nil, nil}
    end
  end
end
