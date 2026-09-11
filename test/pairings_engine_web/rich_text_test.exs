defmodule PairingsEngineWeb.RichTextTest do
  @moduledoc """
  Per-call-site pairing of `<.rich_text>` msgids and their `<:part>` slots.

  ## Why this exists

  `CoreComponents.rich_text/1` substitutes a `<:part name="x">` slot into
  every `%[x]` placeholder in a msgid, and a placeholder with no matching
  slot renders literally rather than vanishing - deliberately, so a
  translator's invented placeholder is visible instead of silently eaten.
  That protects the runtime. It does not protect the other side of the same
  mistake: a developer who renames a msgid's `%[edition]` to `%[date]` and
  forgets to rename the matching `<:part name="edition">` gets the raw text
  `%[date]` rendered in a dialog, and the test suite stays green, because
  nothing anywhere compares a call's placeholders against that same call's
  parts.

  This nearly shipped on 2026-09-10 (commit 99ec711,
  `settings_options_live.ex` around line 994): both sides were renamed
  correctly that time, and a one-off count across the whole codebase found
  47 placeholders and 47 matching slot names. That count was a global set
  comparison, not a per-call-site one - it would have passed just as happily
  with `%[date]` living in one `<.rich_text>` call and `<:part name="date">`
  sitting in an unrelated one three files away. This file does the
  per-call-site version, permanently, as a test.

  ## What it checks

    1. every `%[name]` placeholder in a call's msgid has a `<:part
       name="name">` in that same call;
    2. every `<:part name="name">` in a call has a matching placeholder in
       that call's msgid;
    3. the gap `translations_test.exs` leaves in checking that a `%[name]`
       placeholder survives from msgid to msgstr - see the two tests near
       the bottom of this file for exactly what gap that is and why.

  ## How it finds a call

  Regexing `.ex` and `.heex` source for `<.rich_text ...>...</.rich_text>`
  was tried and abandoned: the `text` attribute is routinely a multi-line
  `gettext(...)` call, sometimes `ngettext/3` with two msgids to check
  instead of one, and the slots inside can nest arbitrary markup including
  other components. Getting that right with regular expressions means
  re-deriving a chunk of an HTML parser, badly. Phoenix already has a good
  one, and `mix format` already trusts it for exactly this file's kind of
  source.

  Each `.ex` file is parsed as Elixir source with `Code.string_to_quoted!/2`
  - parsed, not compiled, so this cannot fail on a module that is not yet
  loaded - purely to find where each `~H` sigil begins. The raw HEEx text of
  that sigil is then handed to `Phoenix.LiveView.TagEngine.Parser`, the
  tokenizer/parser `Phoenix.LiveView.HTMLFormatter` uses to format `~H` and
  `.heex` sources, which returns a real tree instead of a flat token
  stream. A `<.rich_text>` block's `text` attribute is itself Elixir source
  (another `Code.string_to_quoted!/2` pass), and every string literal inside
  it - across `gettext/1,2`, `ngettext/3`'s singular and plural forms,
  whatever argument shape comes next - is scanned for `%[name]`. The
  block's `<:part>` children give the other side of the pairing directly,
  as siblings of that block in the same tree.

  ## What this does not catch

    * A `<:part name={...}>` whose name is not a literal string - computed
      rather than written out - is not checked. Every call site today uses
      a literal; if that stops being true, this quietly stops verifying
      that one part instead of failing loudly. Worth revisiting if it ever
      happens.
    * It does not check `%{...}` gettext interpolation at all - only the
      square-bracket `%[...]` shape `rich_text` owns. The curly shape is
      `translations_test.exs`'s job.
    * It says nothing about whether a slot's rendered content makes sense
      in context - only that its name exists on both sides of the call.
  """

  use ExUnit.Case, async: true

  alias Phoenix.LiveView.TagEngine.Parser

  # A placeholder is `%[name]`, exactly what `CoreComponents.rich_text/1`
  # itself recognises via its own `@placeholder` regex - a leading letter or
  # underscore, never a digit. Kept in sync with that pattern on purpose:
  # this file is checking the same contract the component enforces at
  # runtime, not a looser approximation of it.
  @placeholder ~r/%\[([a-zA-Z_][a-zA-Z0-9_]*)\]/

  defp bracket_placeholders(string) do
    @placeholder
    |> Regex.scan(string)
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ---------------------------------------------------------------------
  # Finding every <.rich_text> call site under lib/
  # ---------------------------------------------------------------------

  # Every `.ex` and `.heex` file under lib/, narrowed to the ones that could
  # possibly call the component. A plain substring check, but an exact one:
  # the call always spells the function name out, so nothing that calls
  # `<.rich_text>` can fail to contain the text "rich_text".
  defp candidate_files do
    (Path.wildcard("lib/**/*.ex") ++ Path.wildcard("lib/**/*.heex"))
    |> Enum.filter(&String.contains?(File.read!(&1), "rich_text"))
  end

  # A `.heex` file's whole content is already HEEx source, starting at line
  # 1. A `.ex` file embeds HEEx inside `~H` sigils; parsing (never compiling)
  # the file finds where each one starts, and everything past that point is
  # handed to Phoenix's own HEEx parser rather than re-derived here.
  defp heex_fragments(path) do
    case Path.extname(path) do
      ".heex" ->
        [{File.read!(path), 0}]

      ".ex" ->
        path
        |> File.read!()
        |> Code.string_to_quoted!(file: path)
        |> Macro.prewalk([], fn
          {:sigil_H, meta, [{:<<>>, _, [raw]} | _]} = node, acc when is_binary(raw) ->
            {node, [{raw, Keyword.fetch!(meta, :line)} | acc]}

          node, acc ->
            {node, acc}
        end)
        |> elem(1)
        |> Enum.reverse()
    end
  end

  defp parse_heex!(path, raw, line_offset) do
    case Parser.parse(raw,
           tag_handler: Phoenix.LiveView.HTMLEngine,
           file: path,
           # No caller environment is available outside of compilation, and
           # none of the call sites this test cares about are macro
           # components anyway - skip rather than fail on the ones that
           # exist elsewhere in these same files (e.g. `<Layouts.app>`).
           skip_macro_components: true
         ) do
      {:ok, tree} ->
        tree

      {:error, line, column, message} ->
        flunk(
          "#{path}:#{line_offset + line}:#{column}: could not parse this HEEx template - #{message}"
        )
    end
  end

  # A `<.rich_text>` call anywhere in the tree, however deep - it is
  # sometimes nested inside another component's own slot.
  defp find_rich_text(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &find_rich_text/1)

  defp find_rich_text(
         {:block, :local_component, "rich_text", attrs, children, open_meta, _close_meta}
       ) do
    [{attrs, children, open_meta} | find_rich_text(children)]
  end

  defp find_rich_text({:block, _type, _name, _attrs, children, _open_meta, _close_meta}) do
    find_rich_text(children)
  end

  defp find_rich_text(_leaf), do: []

  # Every string literal an expression contains, wherever it sits in the
  # call - `gettext("...")`, `ngettext("...", "...", count)`, a keyword
  # argument list after the msgid, all of it. This does not need to know
  # which gettext function is being called: any string literal that is not
  # a msgid simply will not contain a `%[...]` placeholder to find.
  defp string_literals(code) do
    code
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      node, acc when is_binary(node) -> {node, [node | acc]}
      node, acc -> {node, acc}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp call_text(attrs) do
    case List.keyfind(attrs, "text", 0) do
      {"text", {:string, value, _meta}, _attr_meta} -> [value]
      {"text", {:expr, code, _meta}, _attr_meta} -> string_literals(code)
    end
  end

  defp part_names(children) do
    children
    |> Enum.flat_map(fn
      {:block, :slot, "part", attrs, _children, _open_meta, _close_meta} -> [part_name(attrs)]
      {:self_close, :slot, "part", attrs, _meta} -> [part_name(attrs)]
      _other -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp part_name(attrs) do
    case List.keyfind(attrs, "name", 0) do
      {"name", {:string, name, _meta}, _attr_meta} ->
        name

      other ->
        flunk("<:part> has a name attribute this test cannot read statically: #{inspect(other)}")
    end
  end

  defp call_site(path, line_offset, {attrs, children, open_meta}) do
    texts = call_text(attrs)

    %{
      file: path,
      line: line_offset + open_meta.line,
      texts: texts,
      placeholders: texts |> Enum.flat_map(&bracket_placeholders/1) |> Enum.uniq() |> Enum.sort(),
      parts: part_names(children)
    }
  end

  defp call_sites do
    for path <- candidate_files(),
        {raw, line_offset} <- heex_fragments(path),
        tree = parse_heex!(path, raw, line_offset),
        rich_text <- find_rich_text(tree.nodes) do
      call_site(path, line_offset, rich_text)
    end
  end

  test "there are <.rich_text> call sites to check" do
    # Guards the whole file the same way translations_test guards itself: a
    # substring filter or wildcard that quietly stopped matching anything
    # would leave every test below green while checking nothing at all.
    assert call_sites() != []
  end

  test "every %[name] placeholder in a rich_text call has a matching <:part> in that same call" do
    for site <- call_sites() do
      missing = site.placeholders -- site.parts

      assert missing == [],
             """
             #{site.file}:#{site.line}: <.rich_text> has placeholder(s) #{inspect(missing)} with no matching <:part name="..."> in this call.

               msgid: #{inspect(site.texts)}
               parts: #{inspect(site.parts)}
             """
    end
  end

  test "every <:part> in a rich_text call has a matching %[name] placeholder in its msgid" do
    for site <- call_sites() do
      extra = site.parts -- site.placeholders

      assert extra == [],
             """
             #{site.file}:#{site.line}: <.rich_text> has <:part name="..."> #{inspect(extra)} with no matching placeholder in its msgid.

               msgid: #{inspect(site.texts)}
               parts: #{inspect(site.parts)}
             """
    end
  end

  # ---------------------------------------------------------------------
  # Rule 3: msgid -> msgstr, for the gap translations_test leaves open
  # ---------------------------------------------------------------------
  #
  # `translations_test.exs`'s third rule already scans for `%[...]` as well
  # as `%{...}`, because both are fatal the same way if lost. What it does
  # NOT do, worked out by reading it rather than guessed at:
  #
  #   * it only ever looks at the `nl` catalogue - `en` msgstrs are
  #     conventionally left empty, so nothing checks what happens if one
  #     ever stops being empty;
  #   * its drop-direction check ("no singular translation quietly drops a
  #     placeholder") explicitly skips `Expo.Message.Plural` messages,
  #     because a plural form may legitimately omit `%{count}` - English
  #     does exactly that in "1 tournament waiting to send". A `%[...]`
  #     placeholder has no such exception: it names something that belongs
  #     on screen regardless of count, the way `%[audit]` sits in both
  #     forms of "N changes predate the oldest restore point".
  #
  # Its add-direction check ("no translation interpolates something that
  # will not be bound") is NOT restricted to singular messages, so `nl`
  # plurals already have that half covered. The two tests below cover
  # exactly the remainder: `en` in both directions, and `nl` plurals in the
  # drop direction. Repeating what is already covered would only be noise.

  defp catalogue(locale), do: Path.wildcard("priv/gettext/#{locale}/LC_MESSAGES/*.po")

  defp po_messages(path), do: Expo.PO.parse_file!(path).messages

  defp msgid(%Expo.Message.Singular{msgid: msgid}), do: IO.iodata_to_binary(msgid)
  defp msgid(%Expo.Message.Plural{msgid: msgid}), do: IO.iodata_to_binary(msgid)

  defp msgstrs(%Expo.Message.Singular{msgstr: msgstr}), do: [IO.iodata_to_binary(msgstr)]

  defp msgstrs(%Expo.Message.Plural{msgstr: msgstr}) do
    Enum.map(msgstr, fn {_n, str} -> IO.iodata_to_binary(str) end)
  end

  defp available_bracket_placeholders(%Expo.Message.Plural{} = message) do
    plural = IO.iodata_to_binary(message.msgid_plural)
    Enum.sort(Enum.uniq(bracket_placeholders(msgid(message)) ++ bracket_placeholders(plural)))
  end

  defp available_bracket_placeholders(message), do: bracket_placeholders(msgid(message))

  test "no English translation adds, drops or renames a %[name] placeholder" do
    for path <- catalogue("en"), message <- po_messages(path) do
      allowed = available_bracket_placeholders(message)

      for translation <- msgstrs(message), translation != "" do
        found = bracket_placeholders(translation)

        assert found -- allowed == [],
               """
               #{Path.basename(path)}: #{inspect(msgid(message))} interpolates #{inspect(found -- allowed)}, which is not in the msgid.

                 available:   #{inspect(allowed)}
                 translation: #{inspect(translation)}
               """

        assert allowed -- found == [],
               """
               #{Path.basename(path)}: #{inspect(msgid(message))} drops #{inspect(allowed -- found)}.

                 translation: #{inspect(translation)}
               """
      end
    end
  end

  test "no Dutch plural translation drops a %[name] placeholder" do
    for path <- catalogue("nl"), %Expo.Message.Plural{} = message <- po_messages(path) do
      allowed = available_bracket_placeholders(message)

      for translation <- msgstrs(message), translation != "" do
        missing = allowed -- bracket_placeholders(translation)

        assert missing == [],
               """
               #{Path.basename(path)}: #{inspect(msgid(message))} drops #{inspect(missing)}.

                 translation: #{inspect(translation)}
               """
      end
    end
  end
end
