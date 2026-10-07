defmodule PairingsEngine.Manual.Markup do
  @moduledoc """
  Turns one manual chapter's Markdown into the page's HTML, plus what the
  page is built around: the outline, the search sections and the figures.
  Runs at compile time, from `PairingsEngine.Manual`.

  Everything here is plain Markdown that also reads sensibly on GitHub; the
  manual only gives some of it a richer look. The conventions, for whoever
  writes a chapter:

  ## Callouts

  A blockquote whose first line is a marker becomes a callout box (the same
  syntax GitHub uses for its alerts, plus one of our own):

      > [!TIP]
      > Pair the round only after every result is in.

      > [!FIDE] C.04.3, Article 5
      > A player who has already received a pairing-allocated bye ...

  Markers: `NOTE`, `TIP`, `IMPORTANT`, `WARNING`, `CAUTION`, `FIDE` (a FIDE
  rule or a departure from it). Text after the marker on the same line is
  the callout's title; without it the title is the marker's name
  ("FIDE rule" for `FIDE`). The title is plain text.

  ## Steps

  Every numbered list (`1. ...`) is shown as a sequence of steps, so write a
  procedure as one, and a list that is not an order as a bulleted list.

  ## Keyboard keys

  `<kbd>Ctrl</kbd>+<kbd>K</kbd>`: the one piece of inline HTML the manual
  understands. Anything else in angle brackets is shown as written.

  ## Screenshots

  An image on a paragraph of its own becomes a numbered figure:

      ![The Pairings page with round 3 paired](screenshots/pairing-round.png "Round 3, paired")

  The file lives in `priv/static/images/manual/` (served as
  `/images/manual/...`); the alt text describes the picture, the optional
  quoted title is the caption (the alt text is used when there is none).
  Until the file exists the page shows a placeholder naming the file and
  what it should show. Every slot is listed in `priv/manual/SCREENSHOTS.md`.

  ## Links

  A link to another chapter is a relative link to its file,
  `[Printing](09-printing.md)` or `[Swiss](06-pairing.md#swiss)`, and opens
  `/help/printing` (`#swiss`). `##` and `###` headings get an id from their
  text (lower-cased, runs of other characters becoming one `-`).
  """

  alias PairingsEngine.Markdown

  @screenshot_url "/images/manual"

  @callouts %{
    "NOTE" => {"note", "Note", "hero-information-circle"},
    "TIP" => {"tip", "Tip", "hero-light-bulb"},
    "IMPORTANT" => {"important", "Important", "hero-exclamation-circle"},
    "WARNING" => {"warning", "Warning", "hero-exclamation-triangle"},
    "CAUTION" => {"caution", "Caution", "hero-shield-exclamation"},
    "FIDE" => {"fide", "FIDE rule", "hero-scale"}
  }

  @callout_marker ~r/\A\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION|FIDE)\][ \t]*([^\n]*)\n?/s

  @doc """
  Renders `markdown`, the chapter numbered `number`. Options:
  `:screenshot_dir`, the directory a screenshot's file is looked up in.

  Returns `%{title:, html:, toc:, sections:, figures:, summary:}`:
  `toc` is the `##`/`###` headings (`%{id:, text:, level:}`), `sections` the
  chapter cut at those headings for search (`%{id:, heading:, text:}`, the
  first with `id: nil` for the text before the first heading), `figures`
  the screenshot slots (`%{file:, alt:, caption:, present?:, id:, number:}`).
  """
  def chapter(markdown, number, opts \\ []) do
    ast = Markdown.parse(markdown)

    {title, ast} = take_title(ast)

    state = %{
      number: number,
      figure: 0,
      ids: %{},
      toc: [],
      figures: [],
      screenshot_dir: Keyword.get(opts, :screenshot_dir)
    }

    {ast, state} = transform_nodes(ast, state)

    %{
      title: title,
      html: Markdown.render_ast(ast, manual: true),
      toc: Enum.reverse(state.toc),
      sections: sections(ast),
      figures: Enum.reverse(state.figures),
      summary: summary(ast)
    }
  end

  @doc "The visible text of a heading, as its id: lower-cased, other runs as `-`."
  def heading_id(text) do
    id =
      text
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if id == "", do: "section", else: id
  end

  # ---------- the title ----------

  defp take_title([{"h1", _, children, _} | rest]), do: {String.trim(text_of(children)), rest}

  defp take_title(ast) do
    case Enum.split_while(ast, &(not match?({"h1", _, _, _}, &1))) do
      {before, [{"h1", _, children, _} | rest]} ->
        {String.trim(text_of(children)), before ++ rest}

      _ ->
        {"", ast}
    end
  end

  # ---------- the tree walk ----------

  defp transform_nodes(nodes, state) do
    {nodes, state} = Enum.map_reduce(nodes, state, &transform/2)
    {List.flatten(nodes), state}
  end

  # Text: keyboard keys. Code and preformatted blocks are not walked at all
  # (below), so `<kbd>` inside backticks stays literal.
  defp transform(text, state) when is_binary(text), do: {kbd(text), state}

  defp transform({tag, _, _, _} = node, state) when tag in ["code", "pre"], do: {node, state}

  defp transform({"blockquote", _attrs, children, meta} = node, state) do
    case callout(children) do
      {:ok, kind, title, body} ->
        {kind_class, default_title, icon} = Map.fetch!(@callouts, kind)
        {body, state} = transform_nodes(body, state)
        title = if title == "", do: default_title, else: title

        {{"div",
          [
            {"class", "manual-callout manual-callout-#{kind_class}"},
            {"role", "note"},
            {"data-callout", kind_class}
          ],
          [
            {"p", [{"class", "manual-callout-title"}],
             [
               {"span", [{"class", "#{icon} manual-callout-icon"}, {"aria-hidden", "true"}], [],
                %{}},
               title
             ], %{}}
            | body
          ], meta}, state}

      :error ->
        {children, state} = transform_nodes(children, state)
        {put_elem(node, 2, children), state}
    end
  end

  defp transform({"p", _, children, _} = node, state) do
    case Enum.reject(children, &blank?/1) do
      [{"img", attrs, _, _}] ->
        figure(attrs, state)

      _ ->
        {children, state} = transform_nodes(children, state)
        {put_elem(node, 2, children), state}
    end
  end

  defp transform({level, attrs, children, meta}, state) when level in ["h2", "h3"] do
    {children, state} = transform_nodes(children, state)
    text = children |> text_of() |> String.trim()
    {id, state} = unique_id(heading_id(text), state)

    anchor =
      {"a",
       [
         {"class", "manual-anchor"},
         {"href", "#" <> id},
         {"aria-label", "Link to this section: " <> text}
       ], ["#"], %{}}

    toc = %{id: id, text: text, level: if(level == "h2", do: 2, else: 3)}

    {{level, [{"id", id} | drop_attr(attrs, "id")], children ++ [anchor], meta},
     %{state | toc: [toc | state.toc]}}
  end

  defp transform({"ol", attrs, children, meta}, state) do
    {children, state} = transform_nodes(children, state)

    start =
      case List.keyfind(attrs, "start", 0) do
        {"start", value} -> value |> to_string() |> Integer.parse() |> elem(0)
        nil -> 1
      end

    attrs = [{"class", "manual-steps"} | drop_attr(attrs, "class")]

    # The step numbers are a CSS counter, which knows nothing of `start`.
    attrs =
      if start > 1, do: attrs ++ [{"style", "counter-reset: step #{start - 1}"}], else: attrs

    {{"ol", attrs, children, meta}, state}
  end

  defp transform({"table", _, _, _} = table, state) do
    {table, state} = transform_children(table, state)

    {{"div",
      [
        {"class", "manual-table-wrap"},
        {"role", "region"},
        {"aria-label", "Table"},
        {"tabindex", "0"}
      ], [table], %{}}, state}
  end

  defp transform({"a", attrs, children, meta}, state) do
    {children, state} = transform_nodes(children, state)

    attrs =
      Enum.map(attrs, fn
        {"href", href} -> {"href", chapter_href(href)}
        other -> other
      end)

    {{"a", attrs, children, meta}, state}
  end

  defp transform({_, _, _, _} = node, state), do: transform_children(node, state)
  defp transform(other, state), do: {other, state}

  defp transform_children({tag, attrs, children, meta}, state) do
    {children, state} = transform_nodes(children, state)
    {{tag, attrs, children, meta}, state}
  end

  # ---------- callouts ----------

  defp callout([{"p", p_attrs, [first | rest], p_meta} | body]) when is_binary(first) do
    case Regex.run(@callout_marker, first, return: :index) do
      [{0, len}, kind_at, title_at] ->
        kind = binary_part(first, elem(kind_at, 0), elem(kind_at, 1))
        title = first |> binary_part(elem(title_at, 0), elem(title_at, 1)) |> String.trim()
        remainder = binary_part(first, len, byte_size(first) - len)
        children = if remainder == "", do: rest, else: [remainder | rest]

        body =
          if Enum.all?(children, &blank?/1),
            do: body,
            else: [{"p", p_attrs, children, p_meta} | body]

        {:ok, kind, title, body}

      _ ->
        :error
    end
  end

  defp callout(_), do: :error

  # ---------- figures ----------

  defp figure(attrs, state) do
    src = attr(attrs, "src")
    alt = attr(attrs, "alt")

    caption =
      case attr(attrs, "title"),
        do: (
          "" -> alt
          title -> title
        )

    number = state.figure + 1
    label = "Figure #{state.number}.#{number}"

    {file, url, present?} =
      case Regex.run(~r{\Ascreenshots/([A-Za-z0-9][A-Za-z0-9._-]*)\z}, src) do
        [_, file] ->
          present? =
            state.screenshot_dir != nil and File.regular?(Path.join(state.screenshot_dir, file))

          {file, @screenshot_url <> "/" <> file, present?}

        nil ->
          {nil, src, true}
      end

    id = "figure-" <> heading_id(Path.rootname(file || src))
    {id, state} = unique_id(id, state)

    body =
      if present? do
        {"button",
         [
           {"type", "button"},
           {"class", "manual-figure-frame"},
           {"data-enlarge", "true"},
           {"aria-label", "Enlarge " <> label <> ": " <> alt}
         ],
         [
           {"img", [{"src", url}, {"alt", alt}, {"loading", "lazy"}, {"decoding", "async"}], [],
            %{}},
           {"span",
            [{"class", "hero-arrows-pointing-out manual-figure-zoom"}, {"aria-hidden", "true"}],
            [], %{}}
         ], %{}}
      else
        {"div",
         [
           {"class", "manual-figure-placeholder"},
           {"role", "img"},
           {"aria-label", "Screenshot not added yet: " <> alt}
         ],
         [
           {"span", [{"class", "hero-photo manual-placeholder-icon"}, {"aria-hidden", "true"}],
            [], %{}},
           {"span", [{"class", "manual-placeholder-label"}], ["Screenshot to come"], %{}},
           {"code", [{"class", "manual-placeholder-file"}], [file || src], %{}},
           {"span", [{"class", "manual-placeholder-alt"}], [alt], %{}}
         ], %{}}
      end

    node =
      {"figure",
       [
         {"class", if(present?, do: "manual-figure", else: "manual-figure is-missing")},
         {"id", id}
       ],
       [
         body,
         {"figcaption", [],
          [{"span", [{"class", "manual-figure-number"}], [label], %{}}, " " <> caption], %{}}
       ], %{}}

    entry = %{file: file, alt: alt, caption: caption, present?: present?, id: id, number: label}
    {node, %{state | figure: number, figures: [entry | state.figures]}}
  end

  # ---------- links ----------

  # `09-printing.md#anchor` -> `/help/printing#anchor`. Anything else as written.
  defp chapter_href(href) do
    case Regex.run(~r{\A(?:\d+-)?([a-z0-9-]+)\.md(#[^"]*)?\z}, href) do
      [_, slug] -> "/help/" <> slug
      [_, slug, anchor] -> "/help/" <> slug <> anchor
      nil -> href
    end
  end

  # ---------- keyboard keys ----------

  defp kbd(text) do
    if String.contains?(text, "<kbd>") do
      ~r"<kbd>([^<>]{1,40})</kbd>"
      |> Regex.split(text, include_captures: true)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn piece ->
        case Regex.run(~r"\A<kbd>([^<>]{1,40})</kbd>\z", piece) do
          [_, key] -> {"kbd", [], [key], %{}}
          nil -> piece
        end
      end)
    else
      text
    end
  end

  # ---------- search sections ----------

  defp sections(ast) do
    {current, done} =
      Enum.reduce(ast, {%{id: nil, heading: nil, text: []}, []}, fn
        {level, attrs, children, _}, {current, done} when level in ["h2", "h3"] ->
          heading = children |> Enum.reject(&anchor?/1) |> text_of() |> String.trim()
          {%{id: attr(attrs, "id"), heading: heading, text: []}, [current | done]}

        node, {current, done} ->
          {%{current | text: [text_of(node) | current.text]}, done}
      end)

    [current | done]
    |> Enum.reverse()
    |> Enum.map(fn section ->
      text =
        section.text |> Enum.reverse() |> Enum.join(" ") |> String.replace(~r/\s+/, " ")

      %{section | text: String.trim(text)}
    end)
    |> Enum.reject(&(&1.id == nil and &1.text == ""))
  end

  defp summary(ast) do
    case Enum.find(ast, &match?({"p", _, _, _}, &1)) do
      nil ->
        ""

      p ->
        text = p |> text_of() |> String.replace(~r/\s+/, " ") |> String.trim()
        # Whole sentences, until there is enough to say what the chapter is.
        sentence =
          text
          |> String.split(~r/(?<=[.:])\s/)
          |> Enum.reduce_while("", fn s, acc ->
            acc = String.trim(acc <> " " <> s)
            if String.length(acc) >= 70, do: {:halt, acc}, else: {:cont, acc}
          end)

        if String.length(sentence) > 150,
          do: String.slice(sentence, 0, 147) <> "...",
          else: sentence
    end
  end

  # ---------- helpers ----------

  defp text_of(text) when is_binary(text), do: text
  defp text_of(nodes) when is_list(nodes), do: Enum.map_join(nodes, &text_of/1)
  defp text_of({"figure", _, _, _}), do: ""
  defp text_of({"a", [{"class", "manual-anchor"} | _], _, _}), do: ""
  defp text_of({"span", _, [], _}), do: ""

  defp text_of({tag, _, children, _}) when tag in ~w(p li h2 h3 h4 tr td th pre div),
    do: " " <> text_of(children) <> " "

  defp text_of({_, _, children, _}), do: text_of(children)
  defp text_of(_), do: ""

  defp anchor?({"a", [{"class", "manual-anchor"} | _], _, _}), do: true
  defp anchor?(_), do: false

  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_), do: false

  defp attr(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {_, value} -> to_string(value)
      nil -> ""
    end
  end

  defp drop_attr(attrs, name), do: List.keydelete(attrs, name, 0)

  defp unique_id(id, state) do
    case Map.get(state.ids, id) do
      nil -> {id, %{state | ids: Map.put(state.ids, id, 1)}}
      n -> {"#{id}-#{n + 1}", %{state | ids: Map.put(state.ids, id, n + 1)}}
    end
  end
end
