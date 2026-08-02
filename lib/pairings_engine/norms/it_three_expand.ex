defmodule PairingsEngine.Norms.ItThreeExpand do
  @moduledoc """
  Grows the IT3 template to fit arbiters beyond the 4 deputy slots it ships
  with (`Invulformulier` rows 59-69: chief + 1st-4th deputy — see
  `docs/norms.md`). FIDE's own printed `Certificaat` sheet doesn't rank
  those last two by name either ("1st/2nd Deputy Chief Arbiter" then a
  plain, unranked "Arbiter" row twice) — this module keeps extending that
  same unranked "Arbiter" block for however many more are needed, rather
  than inventing a new section.

  A no-op (returns `template_binary` untouched) when `extra_count` is `0` —
  the overwhelming majority of tournaments never need this at all, so the
  common path never touches the template.

  Only the Erlang standard library (`:zip`) plus `Regex`/`String` are used,
  same as `PairingsEngine.Norms.XlsxFill` — this module hand-edits the same
  kind of zip-of-XML `.xlsx` internals, just to grow the sheet rather than
  fill cells (`XlsxFill.fill/2` runs afterwards, against the *expanded*
  template, and needs `arbiter_cell_ref/2` to know where to write).

  ## Why row-insertion instead of a fixed larger template

  FIDE's template only ships 4 deputy slots; there is no "just leave room"
  option for a genuinely unbounded list without either capping arbiters
  arbitrarily (rejected — a real event can have more) or growing the sheet
  on demand. Growing on demand means two coupled edits per extra arbiter,
  one in each sheet:

    * `Invulformulier` gets two new rows (an ID cell, a Name cell) inserted
      right after row 69, before row 70 (`his/her (federation)` — an
      unrelated field used elsewhere in `Certificaat`'s own text, whose row
      number shifts down and whose formula reference has to follow it).
    * `Certificaat` gets two new rows (a label row reading "Arbiter", a row
      of formulas mirroring rows 37-38's exactly — pointing at *this*
      arbiter's new `Invulformulier` cells) inserted right after row 38,
      before row 40 (the "organizer must provide..." note, which — along
      with the privacy notices below it — shifts down by the same amount).

  Every row **after** an insertion point, in the sheet being grown, gets its
  `r="N"` (and every cell ref inside it) renumbered by the shift; any
  formula anywhere in the workbook referencing an `Invulformulier` row at or
  past the insertion point (today, just `Certificaat`'s one
  `Invulformulier!$B$70` reference) gets renumbered the same way. Growing
  `Certificaat` only ever shifts `Certificaat`'s own later rows — nothing
  else references a `Certificaat` cell.
  """

  @invulformulier_insert_after 69
  @invulformulier_last_untouched_row 70

  @certificaat_insert_after 38
  @certificaat_original_last_row 42

  @doc """
  `{id_ref, name_ref}` — the `Invulformulier` cell refs `arbiter_index`
  (1-based, counting only arbiters *beyond* the 4 fixed deputy slots) will
  land on once the template has been `expand/2`-ed for at least that many
  arbiters. Pure and independent of `expand/2` actually having run — the
  layout is deterministic from `arbiter_index` alone — so
  `PairingsEngine.Norms.Forms.it3_fills/3` can compute fills without
  reaching into this module's row-building internals.
  """
  def arbiter_cell_ref(arbiter_index, sheet \\ :invulformulier)

  def arbiter_cell_ref(arbiter_index, :invulformulier) when arbiter_index >= 1 do
    id_row = @invulformulier_insert_after + (arbiter_index - 1) * 2 + 1
    {"B#{id_row}", "B#{id_row + 1}"}
  end

  @doc """
  Expands `template_binary` (an already-read `.xlsx` file's bytes) to fit
  `extra_count` arbiters beyond the 4 built-in deputy slots. Returns the
  binary unchanged when `extra_count` is `0`.
  """
  def expand(template_binary, 0) when is_binary(template_binary), do: template_binary

  def expand(template_binary, extra_count)
      when is_binary(template_binary) and is_integer(extra_count) and extra_count > 0 do
    {:ok, entries} = :zip.unzip(template_binary, [:memory])
    entries = Enum.map(entries, fn {name, bin} -> {List.to_string(name), bin} end)

    {_, invul_xml} = List.keyfind(entries, "xl/worksheets/sheet2.xml", 0)
    {_, cert_xml} = List.keyfind(entries, "xl/worksheets/sheet1.xml", 0)

    shift = extra_count * 2

    invul_xml =
      invul_xml
      |> shift_rows_after(@invulformulier_insert_after, shift)
      |> insert_rows(@invulformulier_insert_after, invulformulier_new_rows(extra_count))
      |> update_dimension(@invulformulier_last_untouched_row + shift)

    cert_xml =
      cert_xml
      |> shift_rows_after(@certificaat_insert_after, shift)
      |> shift_cross_sheet_refs("Invulformulier", @invulformulier_insert_after, shift)
      |> insert_rows(@certificaat_insert_after, certificaat_new_rows(extra_count))
      |> update_dimension(@certificaat_original_last_row + shift)

    entries =
      entries
      |> List.keyreplace("xl/worksheets/sheet2.xml", 0, {"xl/worksheets/sheet2.xml", invul_xml})
      |> List.keyreplace("xl/worksheets/sheet1.xml", 0, {"xl/worksheets/sheet1.xml", cert_xml})

    zip_entries = Enum.map(entries, fn {name, bin} -> {String.to_charlist(name), bin} end)
    {:ok, {_name, binary}} = :zip.create(~c"expanded.xlsx", zip_entries, [:memory])
    binary
  end

  # ---------------------------------------------------------------------
  # Invulformulier — plain label + (empty, unstyled — XlsxFill.fill/2
  # writes the value later) data cell, same shape rows 62-69 already use.
  # ---------------------------------------------------------------------

  defp invulformulier_new_rows(extra_count) do
    Enum.map_join(1..extra_count, "", fn n ->
      {id_ref, name_ref} = arbiter_cell_ref(n, :invulformulier)
      id_row = ref_row(id_ref)
      name_row = ref_row(name_ref)

      label_row(id_row, "A#{id_row}", "ID Arbiter #{n}") <>
        label_row(name_row, "A#{name_row}", "Name Arbiter #{n}")
    end)
  end

  defp label_row(row, ref, text) do
    "<row r=\"#{row}\" spans=\"1:2\">" <>
      "<c r=\"#{ref}\" t=\"inlineStr\"><is><t xml:space=\"preserve\">#{text}</t></is></c>" <>
      "</row>"
  end

  # ---------------------------------------------------------------------
  # Certificaat — mirrors rows 37 (label) / 38 (formula), which is itself
  # the 4th deputy's own row pair, styles and merges included.
  # ---------------------------------------------------------------------

  defp certificaat_new_rows(extra_count) do
    Enum.map_join(1..extra_count, "", fn n ->
      {id_ref, name_ref} = arbiter_cell_ref(n, :invulformulier)
      label_row_num = @certificaat_insert_after + (n - 1) * 2 + 1
      formula_row_num = label_row_num + 1

      certificaat_label_row(label_row_num) <>
        certificaat_formula_row(formula_row_num, id_ref, name_ref)
    end)
  end

  defp certificaat_label_row(row) do
    "<row r=\"#{row}\" spans=\"1:10\" ht=\"12.75\" customHeight=\"1\">" <>
      ~s(<c r="A#{row}" s="6" t="s"><v>102</v></c>) <>
      Enum.map_join(~w(B C D E F G H I), "", &~s(<c r="#{&1}#{row}" s="4"/>)) <>
      ~s(<c r="J#{row}" s="5"/>) <>
      "</row>"
  end

  defp certificaat_formula_row(row, invul_id_ref, invul_name_ref) do
    "<row r=\"#{row}\" spans=\"1:10\" ht=\"20.25\" customHeight=\"1\">" <>
      ~s{<c r="A#{row}" s="52" t="str"><f>IF(ISBLANK(Invulformulier!$#{dollar_ref(invul_id_ref)}),"",Invulformulier!$#{dollar_ref(invul_id_ref)})</f><v/></c>} <>
      ~s(<c r="B#{row}" s="53"/>) <>
      ~s{<c r="C#{row}" s="42" t="str"><f>IF(ISBLANK(Invulformulier!$#{dollar_ref(invul_name_ref)}),"",Invulformulier!$#{dollar_ref(invul_name_ref)})</f><v/></c>} <>
      Enum.map_join(~w(D E F G H I), "", &~s(<c r="#{&1}#{row}" s="42"/>)) <>
      ~s(<c r="J#{row}" s="43"/>) <>
      "</row>" <>
      merge_cell("A#{row}:B#{row}") <> merge_cell("C#{row}:J#{row}")
  end

  # `$B$71` from `B71` — matches the `$COL$ROW` style every other formula
  # in this template already uses.
  defp dollar_ref(ref) do
    [_, col, row] = Regex.run(~r/^([A-Z]+)(\d+)$/, ref)
    "#{col}$#{row}"
  end

  # mergeCell elements aren't inside <sheetData>, so they can't be embedded
  # in the row XML insert_rows/3 splices in — collected here and spliced
  # into <mergeCells> separately by insert_rows/3 (it recognises this
  # sentinel wrapper and routes it there instead of into <sheetData>).
  defp merge_cell(ref), do: "<!--mergeCell:#{ref}-->"

  # ---------------------------------------------------------------------
  # shared row/reference-shifting machinery
  # ---------------------------------------------------------------------

  defp ref_row(ref) do
    [_, row] = Regex.run(~r/^[A-Z]+(\d+)$/, ref)
    String.to_integer(row)
  end

  # Renumbers every `<row r="N">` (and the cell refs inside it) where
  # `N > after_row`, by `shift` — highest row first, so an insert can never
  # collide with an already-renumbered row while this runs.
  defp shift_rows_after(xml, after_row, shift) do
    xml
    |> extract_rows()
    |> Enum.filter(fn {n, _xml} -> n > after_row end)
    |> Enum.sort_by(fn {n, _xml} -> -n end)
    |> Enum.reduce(xml, fn {n, row_xml}, acc ->
      new_row_xml = renumber_row(row_xml, n, n + shift)
      String.replace(acc, row_xml, new_row_xml, global: false)
    end)
  end

  defp extract_rows(xml) do
    Regex.scan(~r/<row r="(\d+)"[^>]*>.*?<\/row>/s, xml)
    |> Enum.map(fn [full, n] -> {String.to_integer(n), full} end)
  end

  defp renumber_row(row_xml, old_n, new_n) do
    row_xml
    |> String.replace(~r/<row r="#{old_n}"(?=[\s>])/, "<row r=\"#{new_n}\"", global: false)
    # \g{1}/\g{2} (not bare \1/\2) — new_n's digits sit immediately after the
    # backreference, and PCRE reads a bare \1 followed by more digits as one
    # ambiguous (usually invalid, silently-empty) group number instead of
    # "group 1, then literal digits" — \g{1} disambiguates explicitly.
    |> then(&Regex.replace(~r/(<c r="[A-Z]+)#{old_n}(")/, &1, "\\g{1}#{new_n}\\g{2}"))
  end

  # Rewrites `"#{sheet_name}!$COL$ROW"` (and the un-prefixed `$COL$ROW`
  # right after it, ISBLANK's own arg — see the formula shape above) for
  # every `ROW > after_row`, wherever it appears in `xml` (a different
  # sheet's formulas, when `sheet_name`'s rows shifted).
  defp shift_cross_sheet_refs(xml, sheet_name, after_row, shift) do
    Regex.replace(
      ~r/#{sheet_name}!\$([A-Z]+)\$(\d+)/,
      xml,
      fn full, col, row ->
        row_n = String.to_integer(row)
        if row_n > after_row, do: "#{sheet_name}!$#{col}$#{row_n + shift}", else: full
      end
    )
  end

  # Splices `new_rows_xml` (as produced by `invulformulier_new_rows/1` or
  # `certificaat_new_rows/1`, possibly carrying `merge_cell/1` sentinels)
  # right after `after_row`, and any collected mergeCell sentinels into
  # `<mergeCells>` (bumping its `count`, creating the element if the sheet
  # doesn't have one yet — Invulformulier doesn't).
  defp insert_rows(xml, after_row, new_rows_xml) do
    {row_xml, merge_xml} = split_merge_sentinels(new_rows_xml)

    xml =
      case Regex.run(~r/<row r="#{after_row}"[^>]*>.*?<\/row>/s, xml) do
        [after_row_xml] ->
          String.replace(xml, after_row_xml, after_row_xml <> row_xml, global: false)

        nil ->
          raise "row #{after_row} not found — template layout has changed, re-verify ItThreeExpand"
      end

    if merge_xml == "", do: xml, else: add_merge_cells(xml, merge_xml)
  end

  defp split_merge_sentinels(xml) do
    merges = Regex.scan(~r/<!--mergeCell:([^>]+)-->/, xml) |> Enum.map(&Enum.at(&1, 1))
    row_only = Regex.replace(~r/<!--mergeCell:[^>]+-->/, xml, "")
    merge_xml = Enum.map_join(merges, "", &~s(<mergeCell ref="#{&1}"/>))
    {row_only, merge_xml}
  end

  defp add_merge_cells(xml, new_merge_xml) do
    case Regex.run(~r/<mergeCells count="(\d+)">(.*?)<\/mergeCells>/s, xml) do
      [full, count, inner] ->
        added = ~r/<mergeCell/ |> Regex.scan(new_merge_xml) |> length()
        new_count = String.to_integer(count) + added

        String.replace(
          xml,
          full,
          "<mergeCells count=\"#{new_count}\">" <> inner <> new_merge_xml <> "</mergeCells>",
          global: false
        )

      nil ->
        added = Regex.scan(~r/<mergeCell/, new_merge_xml) |> length()
        block = "<mergeCells count=\"#{added}\">" <> new_merge_xml <> "</mergeCells>"
        # mergeCells must sit right after sheetData, before any dataValidations/printOptions.
        Regex.replace(~r/(<\/sheetData>)/, xml, "\\1" <> block, global: false)
    end
  end

  defp update_dimension(xml, max_row) do
    Regex.replace(~r/<dimension ref="([A-Z]+)1:([A-Z]+)\d+"\/>/, xml, fn _full,
                                                                         first_col,
                                                                         last_col ->
      ~s(<dimension ref="#{first_col}1:#{last_col}#{max_row}"/>)
    end)
  end
end
