defmodule PairingsEngine.Norms.XlsxFill do
  @moduledoc """
  Fills official FIDE Excel forms **in place** by hand-editing the XML members
  inside an `.xlsx` zip archive, so every bit of original formatting,
  formulas, merges, data validation and sheet/workbook protection survives
  untouched.

  This module is intentionally generic: it knows nothing about any specific
  FIDE form (IT3, FA1, IA1, IT4, ...). Callers pass a template path and a map
  of `sheet name => %{cell ref => value}` and get back the filled workbook as
  a binary.

  Only the Erlang standard library (`:zip`) plus `Regex`/`String` are used —
  no new dependencies.
  """

  @type ref :: String.t()
  @type value :: String.t() | number() | Date.t() | DateTime.t() | NaiveDateTime.t() | nil
  @type fills :: %{optional(String.t()) => %{optional(ref) => value}}
  @type error_reason ::
          {:formula_cell, ref}
          | {:unknown_sheet, String.t()}
          | {:invalid_ref, String.t()}
          | {:missing_entry, String.t()}
          | term()

  @doc """
  Fills `template_path` (a `.xlsx` file on disk) with `fills` and returns the
  resulting workbook as a binary.

  `fills` is `%{"Sheet Name" => %{"B3" => value}}`. `value` may be:

    * a `String.t()` — written as `t="inlineStr"` with `<is><t
      xml:space="preserve">...</t></is>`
    * a number (integer or float) — written as a plain `<v>` (no `t`
      attribute)
    * a `Date.t()`, `DateTime.t()` or `NaiveDateTime.t()` — converted to an
      Excel 1900-date-system serial number and written as a plain `<v>`
    * `nil` — the cell is left untouched

  Returns `{:error, {:formula_cell, ref}}` if a fill targets a cell that
  currently holds a formula (`<f>`) — those are never overwritten. Returns
  other `{:error, reason}` tuples for unresolvable sheet names, malformed
  refs, or zip/XML problems.
  """
  @spec fill(Path.t(), fills()) :: {:ok, binary()} | {:error, error_reason()}
  def fill(template_path, fills) when is_binary(template_path) and is_map(fills) do
    with {:ok, entries} <- unzip(template_path),
         {:ok, workbook_xml} <- fetch_entry(entries, "xl/workbook.xml"),
         {:ok, rels_xml} <- fetch_entry(entries, "xl/_rels/workbook.xml.rels"),
         {:ok, sheet_paths} <- resolve_sheet_paths(fills, workbook_xml, rels_xml),
         {:ok, entries} <- apply_sheet_fills(entries, sheet_paths, fills),
         {:ok, entries} <- apply_force_recalc(entries, workbook_xml),
         {:ok, entries} <- strip_stale_formula_caches(entries),
         {:ok, entries} <- drop_calc_chain(entries),
         {:ok, binary} <- rezip(entries) do
      {:ok, binary}
    end
  end

  # ---------------------------------------------------------------------
  # zip helpers
  # ---------------------------------------------------------------------

  defp unzip(path) do
    case :zip.unzip(String.to_charlist(path), [:memory]) do
      {:ok, entries} ->
        {:ok, Enum.map(entries, fn {name, bin} -> {List.to_string(name), bin} end)}

      {:error, reason} ->
        {:error, {:unzip_failed, reason}}
    end
  end

  defp rezip(entries) do
    zip_entries = Enum.map(entries, fn {name, bin} -> {String.to_charlist(name), bin} end)

    case :zip.create(~c"filled.xlsx", zip_entries, [:memory]) do
      {:ok, {_name, binary}} -> {:ok, binary}
      {:error, reason} -> {:error, {:zip_create_failed, reason}}
    end
  end

  defp fetch_entry(entries, name) do
    case List.keyfind(entries, name, 0) do
      {^name, bin} -> {:ok, bin}
      nil -> {:error, {:missing_entry, name}}
    end
  end

  defp put_entry(entries, name, bin) do
    List.keyreplace(entries, name, 0, {name, bin})
  end

  # ---------------------------------------------------------------------
  # sheet name -> sheet xml path resolution
  # ---------------------------------------------------------------------

  defp resolve_sheet_paths(fills, workbook_xml, rels_xml) do
    name_to_rid = parse_workbook_sheets(workbook_xml)
    rid_to_target = parse_rels(rels_xml)

    fills
    |> Map.keys()
    |> Enum.reduce_while({:ok, %{}}, fn sheet_name, {:ok, acc} ->
      with {:ok, rid} <- Map.fetch(name_to_rid, sheet_name) |> ok_or({:unknown_sheet, sheet_name}),
           {:ok, target} <- Map.fetch(rid_to_target, rid) |> ok_or({:unknown_sheet, sheet_name}) do
        {:cont, {:ok, Map.put(acc, sheet_name, "xl/" <> target)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ok_or(:error, reason), do: {:error, reason}
  defp ok_or({:ok, value}, _reason), do: {:ok, value}

  @sheet_tag_re ~r/<sheet\b[^>]*\/>/

  defp parse_workbook_sheets(workbook_xml) do
    @sheet_tag_re
    |> Regex.scan(workbook_xml)
    |> List.flatten()
    |> Enum.reduce(%{}, fn tag, acc ->
      with [_, name] <- Regex.run(~r/\bname="([^"]*)"/, tag) || [nil, nil],
           [_, rid] <- Regex.run(~r/\br:id="([^"]*)"/, tag) || [nil, nil],
           true <- is_binary(name) and is_binary(rid) do
        Map.put(acc, name, rid)
      else
        _ -> acc
      end
    end)
  end

  @rel_tag_re ~r/<Relationship\b[^>]*\/>/

  defp parse_rels(rels_xml) do
    @rel_tag_re
    |> Regex.scan(rels_xml)
    |> List.flatten()
    |> Enum.reduce(%{}, fn tag, acc ->
      with [_, id] <- Regex.run(~r/\bId="([^"]*)"/, tag) || [nil, nil],
           [_, target] <- Regex.run(~r/\bTarget="([^"]*)"/, tag) || [nil, nil],
           true <- is_binary(id) and is_binary(target) do
        Map.put(acc, id, target)
      else
        _ -> acc
      end
    end)
  end

  # ---------------------------------------------------------------------
  # applying fills to sheet XML members
  # ---------------------------------------------------------------------

  defp apply_sheet_fills(entries, sheet_paths, fills) do
    Enum.reduce_while(fills, {:ok, entries}, fn {sheet_name, cell_fills}, {:ok, entries} ->
      path = Map.fetch!(sheet_paths, sheet_name)

      case fetch_entry(entries, path) do
        {:ok, xml} ->
          case apply_cell_fills(xml, cell_fills) do
            {:ok, new_xml} -> {:cont, {:ok, put_entry(entries, path, new_xml)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_cell_fills(xml, cell_fills) do
    Enum.reduce_while(cell_fills, {:ok, xml}, fn {ref, value}, {:ok, xml} ->
      cond do
        is_nil(value) ->
          {:cont, {:ok, xml}}

        not valid_ref?(ref) ->
          {:halt, {:error, {:invalid_ref, ref}}}

        true ->
          case set_cell(xml, ref, value) do
            {:ok, new_xml} -> {:cont, {:ok, new_xml}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  @ref_re ~r/^([A-Z]+)([0-9]+)$/

  defp valid_ref?(ref), do: Regex.match?(@ref_re, ref)

  defp split_ref(ref) do
    [_, col, row] = Regex.run(@ref_re, ref)
    {col, String.to_integer(row)}
  end

  # ---------------------------------------------------------------------
  # row / cell surgery
  # ---------------------------------------------------------------------

  defp set_cell(xml, ref, value) do
    {col_letters, row_num} = split_ref(ref)

    case find_row_match(xml, row_num) do
      {:found, row_match} ->
        replace_cell_in_row(xml, row_match, ref, col_letters, value)

      :not_found ->
        insert_new_row(xml, row_num, ref, value)
    end
  end

  defp row_regex(row_num) do
    Regex.compile!("<row r=\"#{row_num}\"[^>]*?(?:/>|>[\\s\\S]*?</row>)")
  end

  defp find_row_match(xml, row_num) do
    case Regex.run(row_regex(row_num), xml) do
      [match] -> {:found, match}
      nil -> :not_found
    end
  end

  defp cell_regex(ref) do
    Regex.compile!("<c r=\"#{ref}\"[^>]*?(?:/>|>[\\s\\S]*?</c>)")
  end

  defp find_cell_match(text, ref) do
    case Regex.run(cell_regex(ref), text) do
      [match] -> {:found, match}
      nil -> :not_found
    end
  end

  defp formula_cell?(cell_text), do: String.contains?(cell_text, "<f>") or String.contains?(cell_text, "<f ")

  defp extract_style(cell_text) do
    case Regex.run(~r/\bs="([^"]*)"/, cell_text) do
      [_, style] -> style
      nil -> nil
    end
  end

  defp replace_cell_in_row(xml, row_match, ref, col_letters, value) do
    case find_cell_match(row_match, ref) do
      {:found, cell_match} ->
        if formula_cell?(cell_match) do
          {:error, {:formula_cell, ref}}
        else
          style = extract_style(cell_match)
          new_cell = build_cell_xml(ref, style, value)
          new_row = String.replace(row_match, cell_match, new_cell, global: false)
          {:ok, String.replace(xml, row_match, new_row, global: false)}
        end

      :not_found ->
        new_cell = build_cell_xml(ref, nil, value)
        new_row = insert_cell_into_row(row_match, new_cell, col_letters)
        {:ok, String.replace(xml, row_match, new_row, global: false)}
    end
  end

  # Insert `new_cell` into `row_match` XML text, keeping cells sorted by
  # column. `row_match` is either a self-closing `<row .../>` or a
  # `<row ...>...</row>` element.
  defp insert_cell_into_row(row_match, new_cell, col_letters) do
    target_col = col_to_num(col_letters)

    if String.ends_with?(row_match, "/>") do
      # Empty row element -> give it an open/close form with just this cell.
      opening = String.slice(row_match, 0..-3//1)
      opening <> ">" <> new_cell <> "</row>"
    else
      existing_refs = Regex.scan(~r/<c r="([A-Z]+)[0-9]+"/, row_match) |> Enum.map(&Enum.at(&1, 1))

      insertion_target =
        Enum.find(existing_refs, fn col -> col_to_num(col) > target_col end)

      case insertion_target do
        nil ->
          # append just before the closing </row>
          String.replace(row_match, ~r/<\/row>\z/, new_cell <> "</row>")

        col ->
          # insert right before the first cell in this row whose column is
          # greater than the target column
          case Regex.run(~r/<c r="#{col}[0-9]+"[^>]*?(?:\/>|>[\s\S]*?<\/c>)/, row_match) do
            [existing_cell_match] ->
              String.replace(row_match, existing_cell_match, new_cell <> existing_cell_match, global: false)

            nil ->
              String.replace(row_match, ~r/<\/row>\z/, new_cell <> "</row>")
          end
      end
    end
  end

  defp insert_new_row(xml, row_num, ref, value) do
    new_cell = build_cell_xml(ref, nil, value)
    new_row = "<row r=\"#{row_num}\">" <> new_cell <> "</row>"

    row_numbers =
      Regex.scan(~r/<row r="([0-9]+)"/, xml)
      |> Enum.map(fn [_, n] -> String.to_integer(n) end)

    next_row_num = Enum.find(row_numbers, fn n -> n > row_num end)

    case next_row_num do
      nil ->
        {:ok, String.replace(xml, ~r/<\/sheetData>/, new_row <> "</sheetData>", global: false)}

      n ->
        case find_row_match(xml, n) do
          {:found, next_row_match} ->
            {:ok, String.replace(xml, next_row_match, new_row <> next_row_match, global: false)}

          :not_found ->
            {:error, {:row_insertion_failed, row_num}}
        end
    end
  end

  # ---------------------------------------------------------------------
  # cell XML construction
  # ---------------------------------------------------------------------

  defp build_cell_xml(ref, style, value) do
    s_attr = if style, do: " s=\"#{style}\"", else: ""

    case value do
      %Date{} = date ->
        numeric_cell(ref, s_attr, date_to_serial(date))

      %DateTime{} = dt ->
        numeric_cell(ref, s_attr, datetime_to_serial(dt))

      %NaiveDateTime{} = dt ->
        numeric_cell(ref, s_attr, naive_datetime_to_serial(dt))

      n when is_number(n) ->
        numeric_cell(ref, s_attr, n)

      s when is_binary(s) ->
        string_cell(ref, s_attr, s)
    end
  end

  defp numeric_cell(ref, s_attr, num) do
    "<c r=\"#{ref}\"#{s_attr}><v>#{format_number(num)}</v></c>"
  end

  defp string_cell(ref, s_attr, str) do
    "<c r=\"#{ref}\"#{s_attr} t=\"inlineStr\"><is><t xml:space=\"preserve\">#{escape_xml(sanitize_for_xml(str))}</t></is></c>"
  end

  defp format_number(num) when is_integer(num), do: Integer.to_string(num)

  defp format_number(num) when is_float(num) do
    if num == Float.round(num, 0) and abs(num) < 1.0e15 do
      num |> trunc() |> Integer.to_string()
    else
      Float.to_string(num)
    end
  end

  defp escape_xml(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  # Every string that ends up in a cell here ultimately traces back to
  # user-entered or externally-imported data (tournament/player names,
  # arbiter names, free-text remarks, and — since `PairingsEngine.TrfImport`
  # started back-mapping TRF16 "102"/"112" arbiter lines into
  # `tournament.officials` — names lifted straight out of an uploaded TRF
  # file). `escape_xml/1` only escapes the five reserved XML markup
  # characters; it assumes its input is *already* well-formed text, which
  # two classes of real-world input violate and which Excel's (strict)
  # parser rejects outright — producing exactly the "repair this file"
  # prompt, even though the zip and every other part of the workbook are
  # untouched and fine:
  #
  #   1. Invalid UTF-8 byte sequences. `TrfImport`'s caller reads an
  #      uploaded TRF file with `File.read!/1` — raw bytes, no charset
  #      detection or transcoding. A TRF file saved by arbiter software in
  #      Windows-1252/Latin-1 (common for names with accents, e.g. a
  #      "Boûtchön"-style name) then carries bytes like `0xFC` that are
  #      simply illegal as UTF-8 (XML's *only* legal encoding here, per the
  #      `encoding="UTF-8"` declaration every FIDE template ships with).
  #      SQLite's TEXT storage doesn't validate encoding on write, so the
  #      bad bytes round-trip silently through the database and land
  #      byte-for-byte in the generated sheet XML.
  #   2. XML-illegal C0 control characters (stray NUL/vertical-tab/etc from
  #      a bad paste or a different upstream bug) — legal as UTF-8, but
  #      outright forbidden by the `Char` production in the XML 1.0 spec
  #      (only tab/LF/CR are allowed below U+0020) regardless of escaping;
  #      `&#x0B;` is just as illegal as a literal 0x0B byte.
  #
  # `sanitize_for_xml/1` runs before `escape_xml/1` so both classes are
  # neutralized (replaced with U+FFFD, the standard Unicode replacement
  # character) before the reserved-character escaping happens, guaranteeing
  # every generated `<t>` is valid UTF-8 and legal XML content no matter
  # what the upstream data looked like.
  defp sanitize_for_xml(str) do
    str
    |> sanitize_utf8()
    |> strip_illegal_xml_chars()
  end

  @replacement_char <<0xFFFD::utf8>>

  defp sanitize_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      fix_utf8(binary, [])
    end
  end

  defp fix_utf8(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp fix_utf8(<<codepoint::utf8, rest::binary>>, acc) do
    fix_utf8(rest, [<<codepoint::utf8>> | acc])
  end

  defp fix_utf8(<<_byte, rest::binary>>, acc) do
    fix_utf8(rest, [@replacement_char | acc])
  end

  # XML 1.0's `Char` production only allows #x9 (tab), #xA (LF) and #xD (CR)
  # below #x20 — every other C0 control character is illegal even as a
  # numeric character reference, so these must be replaced, not escaped.
  @illegal_xml_char_re ~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/

  defp strip_illegal_xml_chars(str), do: Regex.replace(@illegal_xml_char_re, str, @replacement_char)

  # ---------------------------------------------------------------------
  # Excel 1900-date-system serial numbers
  # ---------------------------------------------------------------------

  @excel_epoch ~D[1899-12-30]

  defp date_to_serial(%Date{} = date), do: Date.diff(date, @excel_epoch)

  defp datetime_to_serial(%DateTime{} = dt) do
    naive = DateTime.to_naive(dt)
    naive_datetime_to_serial(naive)
  end

  defp naive_datetime_to_serial(%NaiveDateTime{} = ndt) do
    date = NaiveDateTime.to_date(ndt)
    time = NaiveDateTime.to_time(ndt)
    seconds_into_day = time.hour * 3600 + time.minute * 60 + time.second
    fraction = seconds_into_day / 86_400
    date_to_serial(date) + fraction
  end

  # ---------------------------------------------------------------------
  # forced recalculation
  # ---------------------------------------------------------------------

  defp apply_force_recalc(entries, workbook_xml) do
    new_workbook_xml =
      cond do
        Regex.match?(~r/<calcPr\b[^>]*fullCalcOnLoad="[^"]*"[^>]*\/>/, workbook_xml) ->
          workbook_xml

        Regex.match?(~r/<calcPr\b[^>]*\/>/, workbook_xml) ->
          Regex.replace(~r/<calcPr\b([^>]*)\/>/, workbook_xml, "<calcPr\\1 fullCalcOnLoad=\"1\"/>",
            global: false
          )

        true ->
          String.replace(workbook_xml, ~r/<\/sheets>/, "</sheets><calcPr fullCalcOnLoad=\"1\"/>",
            global: false
          )
      end

    {:ok, put_entry(entries, "xl/workbook.xml", new_workbook_xml)}
  end

  # ---------------------------------------------------------------------
  # stale cached formula values
  # ---------------------------------------------------------------------

  # These FIDE templates ship with formula cells whose cached `<v>` (e.g. an
  # empty string or `0`) was baked in when the *unfilled* template was last
  # saved in Excel (verified against the shipped templates in
  # `priv/norm_templates/` — e.g. `Certificaat!A4` ships as
  # `<f>IF(ISBLANK(Invulformulier!$B$1),"",...)</f><v/>`, an empty cached
  # string). `apply_force_recalc/2` sets `fullCalcOnLoad="1"`, but that flag
  # is only a *request* — headless converters, quick-preview panes, and some
  # spreadsheet apps render the cached value as-is without recalculating, so
  # a formula-only sheet like `Certificaat` (which is never a fill target;
  # every value on it is derived from `Invulformulier` via formulas) can
  # render fully blank even though the underlying data was filled correctly.
  #
  # Stripping the cached `<v>` (and the now-meaningless cached-type `t="..."`
  # attribute on the `<c>` tag, e.g. `t="str"`) from every formula cell across
  # every worksheet leaves the `<f>` element intact but removes any value to
  # display, so any compliant reader (Excel, LibreOffice, Google Sheets) is
  # forced to evaluate the formula on open rather than trusting a stale cache
  # — regardless of whether it honors `fullCalcOnLoad`.
  defp strip_stale_formula_caches(entries) do
    entries =
      Enum.map(entries, fn {name, bin} = entry ->
        if worksheet_entry?(name) do
          {name, strip_formula_caches_in_xml(bin)}
        else
          entry
        end
      end)

    {:ok, entries}
  end

  defp worksheet_entry?(name), do: Regex.match?(~r/^xl\/worksheets\/sheet\d+\.xml$/, name)

  # Matches a whole `<c ...>...</c>` element whose first (and only relevant)
  # child is a formula `<f>` — either the full `<f ...>expr</f>` form or the
  # self-closing shared-formula-follower form `<f t="shared" si="1"/>` —
  # optionally followed by a cached `<v>...</v>` / self-closing `<v/>`, which
  # is what gets dropped.
  #
  # ORDER AND LOOKBEHINDS ARE LOAD-BEARING. The FIDE templates cache many
  # formulas as an EMPTY self-closing `<v/>`. An earlier version of the
  # `<v>` branch tried the open-tag form first with a bare `[^>]*>`, which
  # happily eats the `/` of `<v/>` and reads it as an OPENING tag — the
  # lazy `[\s\S]*?<\/v>` then scanned FORWARD ACROSS NEIGHBOURING CELLS to
  # the next real `</v>` anywhere later in the row, and the replacement
  # silently swallowed every cell in between. One minimal fill deleted
  # 99-186 cells from every template's Certificaat/display sheet (the side
  # the arbiter actually reads/prints) — user-reported as norms "not
  # generating Excel properly". Self-closing forms are now matched FIRST,
  # and the open-tag forms' `>` carries a `(?<!\/)` lookbehind so they can
  # never consume a self-closing tag's slash. Same hardening on `<f>` for
  # symmetry. Regression-locked by the cell-preservation invariant test in
  # xlsx_fill_test.exs.
  @formula_cell_re ~r/<c\b([^>]*)>(<f\b[^>]*\/>|<f\b[^>]*(?<!\/)>[\s\S]*?<\/f>)(?:<v\b[^>]*\/>|<v\b[^>]*(?<!\/)>[\s\S]*?<\/v>)?<\/c>/

  defp strip_formula_caches_in_xml(xml) do
    Regex.replace(@formula_cell_re, xml, fn _whole, attrs, f_part ->
      "<c" <> strip_cached_type_attr(attrs) <> ">" <> f_part <> "</c>"
    end)
  end

  defp strip_cached_type_attr(attrs), do: String.replace(attrs, ~r/\s+t="[^"]*"/, "")

  # ---------------------------------------------------------------------
  # calcChain.xml removal
  # ---------------------------------------------------------------------

  # `xl/calcChain.xml` records, for every formula cell, the dependency
  # order Excel last calculated it in — a cache of the *evaluation plan*,
  # not just a value cache. `strip_stale_formula_caches/1` above already
  # invalidates every formula's cached `<v>` (and `apply_force_recalc/2`
  # requests a full recalc on open), which means the calc chain's recorded
  # order no longer corresponds to anything Excel can trust: it was built
  # against the *unfilled* template's cell contents, not the ones this
  # module just wrote into the `Invulformulier` input sheet that
  # `Certificaat`'s formulas read from. Leaving a stale calc chain in place
  # is exactly the kind of "some content" Excel's strict OOXML loader
  # rejects at open time and offers to "repair" — dropping the part
  # entirely (plus its `[Content_Types].xml` override and its
  # `xl/_rels/workbook.xml.rels` relationship, since a dangling reference
  # to a part that no longer exists is its own corruption) is the
  # Microsoft-documented remedy: Excel unconditionally rebuilds
  # `calcChain.xml` from scratch on save/open when the part is simply
  # absent, so nothing is lost by removing it.
  defp drop_calc_chain(entries) do
    if List.keymember?(entries, "xl/calcChain.xml", 0) do
      entries =
        entries
        |> List.keydelete("xl/calcChain.xml", 0)
        |> update_entry("[Content_Types].xml", &remove_calc_chain_content_type/1)
        |> update_entry("xl/_rels/workbook.xml.rels", &remove_calc_chain_relationship/1)

      {:ok, entries}
    else
      {:ok, entries}
    end
  end

  defp update_entry(entries, name, fun) do
    case List.keyfind(entries, name, 0) do
      {^name, bin} -> put_entry(entries, name, fun.(bin))
      nil -> entries
    end
  end

  @calc_chain_content_type_re ~r/<Override\b[^>]*PartName="\/xl\/calcChain\.xml"[^>]*\/>/

  defp remove_calc_chain_content_type(xml), do: Regex.replace(@calc_chain_content_type_re, xml, "")

  @calc_chain_relationship_re ~r/<Relationship\b[^>]*Target="calcChain\.xml"[^>]*\/>/

  defp remove_calc_chain_relationship(xml), do: Regex.replace(@calc_chain_relationship_re, xml, "")

  # col_to_num/1 : "A" -> 1, "Z" -> 26, "AA" -> 27, ...
  defp col_to_num(col_letters) do
    col_letters
    |> String.to_charlist()
    |> Enum.reduce(0, fn char, acc -> acc * 26 + (char - ?A + 1) end)
  end
end
