defmodule PairingsEngine.Norms.XlsxFillTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.Norms.XlsxFill

  @templates_dir Path.join([File.cwd!(), "priv", "norm_templates"])
  @it3 Path.join(@templates_dir, "IT3-TournamentReportForm.xlsx")
  @fa1 Path.join(@templates_dir, "FA1-norm.xlsx")
  @ia1 Path.join(@templates_dir, "IA1-norm.xlsx")
  @it4 Path.join(@templates_dir, "IT4.xlsx")

  # ---------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------

  defp unzip_map(binary) do
    tmp =
      Path.join(System.tmp_dir!(), "xlsx_fill_test_#{System.unique_integer([:positive])}.xlsx")

    File.write!(tmp, binary)

    {:ok, entries} = :zip.unzip(String.to_charlist(tmp), [:memory])
    File.rm(tmp)

    Map.new(entries, fn {name, bin} -> {List.to_string(name), bin} end)
  end

  defp unzip_template_map(path) do
    {:ok, entries} = :zip.unzip(String.to_charlist(path), [:memory])
    Map.new(entries, fn {name, bin} -> {List.to_string(name), bin} end)
  end

  # Strict well-formedness check for a single XML part, independent of the
  # `Regex`-based surgery this module does to produce it. `:xmerl_scan` (part
  # of the Erlang/OTP standard library - no new dep) is a real, validating
  # XML parser, unlike the module's own regexes: it rejects invalid UTF-8,
  # XML-illegal control characters, and any other well-formedness violation
  # that a lenient reader (openpyxl, some quick-preview panes) would happily
  # skip past but Excel's own strict parser does not - that gap is exactly
  # what produced the "we found a problem with some content" repair prompt
  # this module now guards against.
  defp assert_well_formed_xml!(name, binary) do
    assert String.valid?(binary), "#{name}: not valid UTF-8"

    # `:xmerl_scan` decodes UTF-8 itself (per the `encoding="UTF-8"` XML
    # prolog every part here has) when given the *raw bytes* as a charlist
    # (`:erlang.binary_to_list/1`, one list element per byte). Feeding it
    # `String.to_charlist/1`'s *already-decoded* Unicode codepoints instead
    # double-decodes multi-byte characters and misfires as a bogus
    # `bad_character` error on perfectly legal text (e.g. the FIDE
    # template's own "…" in `sharedStrings.xml`) - this must stay raw bytes.
    charlist = :erlang.binary_to_list(binary)

    case :xmerl_scan.string(charlist, quiet: true) do
      {_parsed, _rest} ->
        :ok

      other ->
        flunk("#{name}: xmerl_scan did not return a parsed document, got: #{inspect(other)}")
    end
  rescue
    e -> flunk("#{name}: not well-formed XML (#{Exception.message(e)})")
  catch
    :exit, reason -> flunk("#{name}: xmerl_scan exited: #{inspect(reason)}")
  end

  # Every XML/rels part of a filled workbook must be strictly well-formed,
  # not just the parts this module directly edited - `:zip.create/3` never
  # touches untouched members, but this is the guard that would catch it if
  # it ever did.
  defp assert_all_parts_well_formed!(members) do
    Enum.each(members, fn {name, bin} ->
      if String.ends_with?(name, ".xml") or String.ends_with?(name, ".rels") do
        assert_well_formed_xml!(name, bin)
      end
    end)
  end

  # ---------------------------------------------------------------------
  # IT3
  # ---------------------------------------------------------------------

  describe "IT3 template" do
    test "fills Invulformulier string and date cells in place" do
      assert {:ok, binary} =
               XlsxFill.fill(@it3, %{
                 "Invulformulier" => %{
                   "B3" => "Test Open 2026",
                   "B7" => ~D[2026-07-12]
                 }
               })

      members = unzip_map(binary)
      sheet_xml = Map.fetch!(members, "xl/worksheets/sheet2.xml")

      assert sheet_xml =~
               ~r/<c r="B3"[^>]*t="inlineStr"><is><t xml:space="preserve">Test Open 2026<\/t><\/is><\/c>/

      # B7 keeps its own explicit dd/mm/yyyy style (not the template's
      # original s="12" - see `docs/norms.md`'s date-format note) and gets a
      # bare numeric Excel-serial <v> for the date.
      expected_serial = Date.diff(~D[2026-07-12], ~D[1899-12-30])
      assert sheet_xml =~ ~r/<c r="B7" s="\d+"><v>#{expected_serial}<\/v><\/c>/
    end

    test "refuses to overwrite formula cells and leaves the archive untouched" do
      assert {:error, {:formula_cell, "B30"}} =
               XlsxFill.fill(@it3, %{"Invulformulier" => %{"B30" => 999}})
    end

    test "untouched zip members are byte-identical to the template, except calcChain removal" do
      template_members = unzip_template_map(@it3)

      {:ok, binary} =
        XlsxFill.fill(@it3, %{"Invulformulier" => %{"B3" => "Test Open 2026"}})

      filled_members = unzip_map(binary)

      # sheet2.xml (Invulformulier) gets the actual fill; sheet1.xml
      # (Certificaat, 100% formulas) and sheet2.xml's own formula cells
      # (B30 etc.) both get their stale cached `<v>` stripped so every
      # reader is forced to recompute rather than trust a cache baked in
      # when the template was last saved unfilled; workbook.xml gains
      # fullCalcOnLoad. xl/calcChain.xml is dropped entirely (see
      # `drop_calc_chain/1`), which also touches its `[Content_Types].xml`
      # override and its `xl/_rels/workbook.xml.rels` relationship.
      changed =
        MapSet.new([
          "xl/worksheets/sheet1.xml",
          "xl/worksheets/sheet2.xml",
          "xl/workbook.xml",
          "[Content_Types].xml",
          "xl/_rels/workbook.xml.rels"
        ])

      # calcChain.xml itself is removed, not merely changed.
      assert map_size(template_members) == map_size(filled_members) + 1
      refute Map.has_key?(filled_members, "xl/calcChain.xml")

      Enum.each(template_members, fn {name, bin} ->
        cond do
          name == "xl/calcChain.xml" ->
            :ok

          MapSet.member?(changed, name) ->
            :ok

          true ->
            assert bin == Map.fetch!(filled_members, name),
                   "expected #{name} to be byte-identical"
        end
      end)
    end

    test "drops calcChain.xml and its Content_Types/rels references so no dangling part remains" do
      template_members = unzip_template_map(@it3)
      assert Map.has_key?(template_members, "xl/calcChain.xml")
      assert template_members["[Content_Types].xml"] =~ "calcChain"
      assert template_members["xl/_rels/workbook.xml.rels"] =~ "calcChain"

      {:ok, binary} = XlsxFill.fill(@it3, %{"Invulformulier" => %{"B3" => "Test Open 2026"}})
      members = unzip_map(binary)

      refute Map.has_key?(members, "xl/calcChain.xml")
      refute Map.fetch!(members, "[Content_Types].xml") =~ "calcChain"
      refute Map.fetch!(members, "xl/_rels/workbook.xml.rels") =~ "calcChain"

      assert_all_parts_well_formed!(members)
    end

    test "sets fullCalcOnLoad on workbook.xml while preserving the existing calcId" do
      {:ok, binary} =
        XlsxFill.fill(@it3, %{"Invulformulier" => %{"B3" => "Test Open 2026"}})

      members = unzip_map(binary)
      workbook_xml = Map.fetch!(members, "xl/workbook.xml")

      assert workbook_xml =~ ~r/<calcPr[^>]*calcId="191029"[^>]*fullCalcOnLoad="1"[^>]*\/>/
    end

    test "strips the stale cached <v> from Certificaat's formula cells so they can't render blank/stale" do
      # The shipped template itself bakes in a stale cached value for this
      # cell (an empty cached string, `<v/>`, from when the template was
      # last saved unfilled in Excel) - reproduces the reported bug where
      # the Certificaat sheet displayed blank even though Invulformulier had
      # correct data, because non-recalculating readers just show the cache.
      template_members = unzip_template_map(@it3)
      original_certificaat = Map.fetch!(template_members, "xl/worksheets/sheet1.xml")
      # The style index is deliberately NOT pinned: it is presentation, it
      # changes whenever FIDE re-saves the template (39 -> 54 in the
      # 2026-08-21 revision), and pinning it turns a cosmetic upstream edit
      # into a red build that says nothing about the behaviour under test.
      assert original_certificaat =~ ~r/<c r="A4" s="\d+" t="str"><f>[^<]*<\/f><v\/><\/c>/

      {:ok, binary} =
        XlsxFill.fill(@it3, %{"Invulformulier" => %{"B1" => "FIDE"}})

      members = unzip_map(binary)
      certificaat = Map.fetch!(members, "xl/worksheets/sheet1.xml")

      # <f> survives, <v> and the now-meaningless cached-type t="str" are gone.
      assert certificaat =~ ~r/<c r="A4" s="\d+"><f>[^<]*<\/f><\/c>/
      refute certificaat =~ ~r/<c r="A4"[^>]*><f>[^<]*<\/f><v/

      # B23 shipped with a cached numeric `0` (`<v>0<\/v>`) - also stripped.
      assert Map.fetch!(template_members, "xl/worksheets/sheet1.xml") =~
               ~r/<c r="B23" s="\d+"><f>[^<]*<\/f><v>0<\/v><\/c>/

      assert certificaat =~ ~r/<c r="B23" s="\d+"><f>[^<]*<\/f><\/c>/
    end

    test "also strips stale cached values from Invulformulier's own formula cells (e.g. B30)" do
      {:ok, binary} =
        XlsxFill.fill(@it3, %{"Invulformulier" => %{"B1" => "FIDE"}})

      members = unzip_map(binary)
      sheet_xml = Map.fetch!(members, "xl/worksheets/sheet2.xml")

      assert sheet_xml =~ ~r/<c r="B30"[^>]*><f>B27-B29<\/f><\/c>/
    end
  end

  # ---------------------------------------------------------------------
  # FA1
  # ---------------------------------------------------------------------

  describe "FA1 template" do
    test "fills Invulformulier B8 date, replacing the empty styled placeholder cell" do
      assert {:ok, binary} =
               XlsxFill.fill(@fa1, %{"Invulformulier" => %{"B8" => ~D[2026-01-05]}})

      members = unzip_map(binary)
      sheet_xml = Map.fetch!(members, "xl/worksheets/sheet1.xml")

      expected_serial = Date.diff(~D[2026-01-05], ~D[1899-12-30])
      assert sheet_xml =~ ~r/<c r="B8" s="\d+"><v>#{expected_serial}<\/v><\/c>/
    end

    test "overwrites a pre-filled Belgian-federation default cell (t=\"s\" -> inlineStr)" do
      assert {:ok, binary} = XlsxFill.fill(@fa1, %{"Invulformulier" => %{"B5" => "NED"}})

      members = unzip_map(binary)
      sheet_xml = Map.fetch!(members, "xl/worksheets/sheet1.xml")

      assert sheet_xml =~
               ~r/<c r="B5"[^>]*t="inlineStr"><is><t xml:space="preserve">NED<\/t><\/is><\/c>/

      refute sheet_xml =~ ~r/<c r="B5"[^>]*t="s">/
    end
  end

  # ---------------------------------------------------------------------
  # IA1
  # ---------------------------------------------------------------------

  describe "IA1 template" do
    test "fills Invulformulier B1..B4 like FA1's identical structure" do
      assert {:ok, binary} =
               XlsxFill.fill(@ia1, %{
                 "Invulformulier" => %{
                   "B1" => "Doe",
                   "B2" => "Jane",
                   "B3" => 123_456,
                   "B4" => "BEL"
                 }
               })

      members = unzip_map(binary)
      sheet_xml = Map.fetch!(members, "xl/worksheets/sheet1.xml")

      assert sheet_xml =~
               ~r/<c r="B1"[^>]*t="inlineStr"><is><t xml:space="preserve">Doe<\/t><\/is><\/c>/

      assert sheet_xml =~ ~r/<c r="B3"[^>]*><v>123456<\/v><\/c>/
    end
  end

  # ---------------------------------------------------------------------
  # IT4
  # ---------------------------------------------------------------------

  describe "IT4 template" do
    test "fills header block and a player row, including the merged-anchor cell" do
      assert {:ok, binary} =
               XlsxFill.fill(@it4, %{
                 "IT 4" => %{
                   "A4" => "BEL",
                   "V6" => ~D[2026-03-01],
                   "Z6" => ~D[2026-03-10],
                   "C11" => "Player One",
                   "N11" => 2450
                 }
               })

      members = unzip_map(binary)
      sheet_xml = Map.fetch!(members, "xl/worksheets/sheet1.xml")

      assert sheet_xml =~
               ~r/<c r="A4"[^>]*t="inlineStr"><is><t xml:space="preserve">BEL<\/t><\/is><\/c>/

      assert sheet_xml =~
               ~r/<c r="C11" s="87" t="inlineStr"><is><t xml:space="preserve">Player One<\/t><\/is><\/c>/

      assert sheet_xml =~ ~r/<c r="N11" s="86"><v>2450<\/v><\/c>/

      # sibling cells in row 11 (e.g. D11, O11) must be untouched
      assert sheet_xml =~ ~r/<c r="D11" s="87"\/>/
      assert sheet_xml =~ ~r/<c r="O11" s="86"\/>/
    end

    test "refuses to overwrite the Z column verdict formula" do
      assert {:error, {:formula_cell, "Z11"}} =
               XlsxFill.fill(@it4, %{"IT 4" => %{"Z11" => "Awarded"}})
    end

    test "refuses to overwrite the AF column verdict formula" do
      assert {:error, {:formula_cell, "AF11"}} =
               XlsxFill.fill(@it4, %{"IT 4" => %{"AF11" => "Awarded"}})
    end

    test "gains fullCalcOnLoad on workbook.xml after a successful fill" do
      {:ok, binary} = XlsxFill.fill(@it4, %{"IT 4" => %{"A4" => "BEL"}})

      members = unzip_map(binary)
      workbook_xml = Map.fetch!(members, "xl/workbook.xml")

      assert workbook_xml =~ ~r/<calcPr[^>]*fullCalcOnLoad="1"[^>]*\/>/
    end
  end

  # ---------------------------------------------------------------------
  # cross-cutting behaviour
  # ---------------------------------------------------------------------

  describe "value handling" do
    test "nil values are skipped entirely (cell left untouched)" do
      {:ok, binary} = XlsxFill.fill(@it3, %{"Invulformulier" => %{"B3" => nil}})

      members = unzip_map(binary)
      sheet_xml = Map.fetch!(members, "xl/worksheets/sheet2.xml")

      # B3 was never inserted as a <c> element (nil is a genuine no-op fill).
      refute sheet_xml =~ ~r/<c r="B3"[^>]*>/
    end

    test "unknown sheet name returns an error" do
      assert {:error, {:unknown_sheet, "Nope"}} = XlsxFill.fill(@it3, %{"Nope" => %{"B3" => "x"}})
    end
  end

  # ---------------------------------------------------------------------
  # cell-preservation invariant (formula-cache strip must never eat cells)
  # ---------------------------------------------------------------------

  # Reproduces the reported "norms don't generate Excel properly" bug: the
  # FIDE templates cache many formulas as an EMPTY self-closing `<v/>`, and
  # `strip_stale_formula_caches/1`'s old regex read `<v/>` as an OPENING
  # `<v>` tag (its `[^>]*` ate the slash), then lazily scanned FORWARD
  # ACROSS NEIGHBOURING CELLS to the next real `</v>` later in the row and
  # silently swallowed every cell in between - one minimal fill deleted
  # 99-186 cells from every template's Certificaat/display sheet (the side
  # the arbiter reads/prints; the Invulformulier fills themselves survived,
  # which is why the cell-content assertions above never caught it).
  describe "filling never deletes template cells" do
    for {kind, path, sheet, ref} <- [
          {"IT3", :it3_path, "Invulformulier", "B3"},
          {"FA1", :fa1_path, "Invulformulier", "B1"},
          {"IA1", :ia1_path, "Invulformulier", "B1"},
          {"IT4", :it4_path, "IT 4", "A4"}
        ] do
      test "#{kind}: every worksheet keeps its full template cell set after a fill" do
        path =
          case unquote(path) do
            :it3_path -> @it3
            :fa1_path -> @fa1
            :ia1_path -> @ia1
            :it4_path -> @it4
          end

        template_members = unzip_template_map(path)
        {:ok, binary} = XlsxFill.fill(path, %{unquote(sheet) => %{unquote(ref) => "x"}})
        filled_members = unzip_map(binary)

        for {name, template_xml} <- template_members,
            String.match?(name, ~r/^xl\/worksheets\/sheet\d+\.xml$/) do
          template_refs = cell_ref_set(template_xml)
          filled_refs = cell_ref_set(Map.fetch!(filled_members, name))

          lost = MapSet.difference(template_refs, filled_refs)

          assert MapSet.size(lost) == 0,
                 "#{unquote(kind)} #{name}: filling #{unquote(ref)} deleted template cells: " <>
                   inspect(Enum.sort(lost))
        end
      end
    end

    test "IT4: a full candidate row's remarks (AB column, past the Z-column verdict formula) lands" do
      # AB11 sits right after the Z11 verdict formula's `<v/>` empty cache -
      # exactly the span the old regex swallowed (AA11, AB11, AD11 all
      # vanished, taking the remarks fill with them).
      assert {:ok, binary} = XlsxFill.fill(@it4, %{"IT 4" => %{"AB11" => "board 2 tie split"}})

      sheet_xml = unzip_map(binary) |> Map.fetch!("xl/worksheets/sheet1.xml")

      assert sheet_xml =~
               ~r/<c r="AB11"[^>]*t="inlineStr"><is><t xml:space="preserve">board 2 tie split<\/t><\/is><\/c>/

      for ref <- ~w(AA11 AD11 AE11 Z11 AF11) do
        assert sheet_xml =~ ~s(<c r="#{ref}"), "IT4: template cell #{ref} was deleted"
      end
    end

    defp cell_ref_set(sheet_xml) do
      Regex.scan(~r/<c r="([A-Z]+\d+)"/, sheet_xml)
      |> Enum.map(&Enum.at(&1, 1))
      |> MapSet.new()
    end
  end

  # ---------------------------------------------------------------------
  # hostile data / xlsx corruption regression
  # ---------------------------------------------------------------------

  describe "hostile string data never corrupts the generated xlsx" do
    test "XML metacharacters (& < > \" ') are escaped and every part stays well-formed" do
      hostile = ~s(O'Brien & <Sons> "Chess" Club)

      assert {:ok, binary} = XlsxFill.fill(@it3, %{"Invulformulier" => %{"B3" => hostile}})

      members = unzip_map(binary)
      sheet_xml = Map.fetch!(members, "xl/worksheets/sheet2.xml")

      assert sheet_xml =~
               ~r/<c r="B3"[^>]*t="inlineStr"><is><t xml:space="preserve">O&apos;Brien &amp; &lt;Sons&gt; &quot;Chess&quot; Club<\/t><\/is><\/c>/

      assert_all_parts_well_formed!(members)
    end

    test "non-ASCII text round-trips untouched and every part stays well-formed" do
      hostile = "Gaëtan Boûtchön - Müller"

      assert {:ok, binary} = XlsxFill.fill(@it3, %{"Invulformulier" => %{"B3" => hostile}})

      members = unzip_map(binary)
      sheet_xml = Map.fetch!(members, "xl/worksheets/sheet2.xml")

      assert sheet_xml =~
               ~r/<c r="B3"[^>]*t="inlineStr"><is><t xml:space="preserve">Gaëtan Boûtchön - Müller<\/t><\/is><\/c>/

      assert_all_parts_well_formed!(members)
    end

    # Reproduces the reported bug: a TRF file (or any other upstream text
    # source) whose bytes are Windows-1252/Latin-1 rather than UTF-8 - read
    # raw (`File.read!/1`, no transcoding) by `PairingsEngine.TrfImport`'s
    # caller - carries byte sequences that are simply illegal UTF-8. SQLite
    # doesn't validate encoding on TEXT columns, so a name like this can
    # reach `XlsxFill.fill/2` completely unchanged from what was uploaded.
    # Before the fix, these raw invalid bytes landed byte-for-byte inside
    # the `<t>` element, producing a sheet XML that fails to even decode as
    # UTF-8 (let alone parse) - exactly the "we found a problem with some
    # content" Excel repair prompt from the bug report.
    test "invalid UTF-8 byte sequences (mis-encoded TRF import data) are sanitized, not corrupted through" do
      invalid_utf8_name = <<"Bo", 0xFC, "tchon, Ga", 0xEB, "tan">>
      refute String.valid?(invalid_utf8_name)

      assert {:ok, binary} =
               XlsxFill.fill(@it3, %{"Invulformulier" => %{"B3" => invalid_utf8_name}})

      members = unzip_map(binary)
      sheet_xml = Map.fetch!(members, "xl/worksheets/sheet2.xml")

      assert String.valid?(sheet_xml)
      refute sheet_xml =~ <<0xFC>>
      refute sheet_xml =~ <<0xEB>>
      # the illegal bytes are replaced with the Unicode replacement
      # character, not silently dropped (which would merge unrelated text).
      assert sheet_xml =~ "Bo�tchon, Ga�tan"

      assert_all_parts_well_formed!(members)
    end

    test "XML-illegal C0 control characters are sanitized even though they're valid UTF-8" do
      # \x0B (vertical tab) is legal UTF-8 but outright forbidden by XML
      # 1.0's Char production below \x20 (only tab/LF/CR are legal there) -
      # escaping it as `&#xB;` is just as illegal as the raw byte, so it
      # must be replaced, not merely escaped.
      hostile = "Weird\x0BName\x00Here"

      assert {:ok, binary} = XlsxFill.fill(@it3, %{"Invulformulier" => %{"B3" => hostile}})

      members = unzip_map(binary)
      sheet_xml = Map.fetch!(members, "xl/worksheets/sheet2.xml")

      refute sheet_xml =~ <<0x0B>>
      refute sheet_xml =~ <<0x00>>

      assert_all_parts_well_formed!(members)
    end

    test "hostile data across every fillable cell in an IT3 still produces a fully well-formed workbook" do
      hostile = ~s(O'Brien & <Sons> "Café" - Boûtchön) <> <<0xFC>>

      fills = %{
        "Invulformulier" => %{
          "B1" => hostile,
          "B3" => hostile,
          "B9" => hostile,
          "B60" => hostile,
          "B63" => hostile,
          "B23" => hostile
        }
      }

      assert {:ok, binary} = XlsxFill.fill(@it3, fills)

      members = unzip_map(binary)
      assert_all_parts_well_formed!(members)
    end
  end

  # ---------------------------------------------------------------------
  # cell ordering invariant (Excel repair-prompt regression)
  # ---------------------------------------------------------------------

  # Excel's own (strict) OOXML loader requires the `<c>` children of a
  # `<row>` to appear in ascending column order - a `<c r="C5">` written
  # after a `<c r="B5">` but before-in-source-order a `<c r="A5">` is
  # exactly the class of "problem with some content" that triggers the
  # repair prompt even though every part is otherwise well-formed XML
  # (lenient readers like openpyxl/xmerl don't enforce this ordering, so
  # `assert_all_parts_well_formed!/1` alone can't catch it). This exercises
  # `insert_cell_into_row/3` and `insert_new_row/4` across every row IT3's
  # `it3_fills/2`-shaped payload touches, both cells that replace an
  # existing (possibly empty/self-closing) `<c>` and cells inserted into
  # rows the template ships with none.
  describe "cell ordering invariant" do
    defp cell_refs_in_document_order(sheet_xml) do
      Regex.scan(~r/<c r="([A-Z]+)(\d+)"/, sheet_xml)
      |> Enum.map(fn [_, col, row] -> {String.to_integer(row), col} end)
    end

    defp col_to_num(col) do
      col
      |> String.to_charlist()
      |> Enum.reduce(0, fn char, acc -> acc * 26 + (char - ?A + 1) end)
    end

    defp assert_ascending_column_order_per_row!(sheet_name, sheet_xml) do
      sheet_xml
      |> cell_refs_in_document_order()
      |> Enum.chunk_by(fn {row, _col} -> row end)
      |> Enum.each(fn cells_in_row ->
        cols = Enum.map(cells_in_row, fn {_row, col} -> col_to_num(col) end)

        assert cols == Enum.sort(cols),
               "#{sheet_name}: row #{elem(hd(cells_in_row), 0)} has out-of-order cells: " <>
                 inspect(Enum.map(cells_in_row, fn {row, col} -> "#{col}#{row}" end))
      end)
    end

    test "every row of a fully-filled IT3 keeps ascending column order, with no dangling calcChain" do
      tournament =
        struct(PairingsEngine.Tournaments.Tournament, %{
          name: "Test Open 2026",
          type: "team-swiss",
          federation: "BEL",
          venue: "Chess Hall",
          city: "Brussels",
          start_date: "2026-07-10",
          end_date: "2026-07-18",
          organizer: "Jane Organizer",
          chief_arbiter: "John Arbiter",
          time_control: "90 min + 30 sec/move",
          rounds_count: 9,
          standard: "standard",
          acceleration: "baku",
          event_code: "BEL2026001",
          fide_tournament_id: "12345",
          round_dates: ["2026-07-10", "2026-07-11", "2026-07-11", "2026-07-12"],
          officials: %{
            "organizer_id" => "999001",
            "organizer_email" => "organizer@example.com",
            "chief_arbiter_fide_id" => "888001",
            "chief_arbiter_email" => "arbiter@example.com",
            "deputy1_name" => "Deputy One",
            "deputy1_fide_id" => "777001",
            "deputy2_name" => "Deputy Two",
            "deputy2_fide_id" => "777002",
            "extra_arbiters_count" => 1,
            "arbiter1_name" => "Arbiter One",
            "arbiter1_fide_id" => "777003",
            "swiss_variant" => "Dutch",
            "pairing_mode" => "computerized",
            "pairing_program" => "OpenPairings",
            "remark1" => "First remark",
            "remark2" => "Second remark",
            "remark3" => "Third remark",
            "remark4" => "Fourth remark"
          }
        })

      players =
        for i <- 1..12 do
          struct(PairingsEngine.Tournaments.Player, %{
            name: "Player #{i}",
            federation: if(rem(i, 3) == 0, do: "NED", else: "BEL"),
            fide_rating: 1500 + i * 10,
            title: Enum.at(["GM", "IM", "FM", nil], rem(i, 4))
          })
        end

      fills = PairingsEngine.Norms.Forms.it3_fills(tournament, players)

      assert {:ok, binary} = XlsxFill.fill(@it3, fills)
      members = unzip_map(binary)

      assert_ascending_column_order_per_row!(
        "sheet1.xml (Certificaat)",
        Map.fetch!(members, "xl/worksheets/sheet1.xml")
      )

      assert_ascending_column_order_per_row!(
        "sheet2.xml (Invulformulier)",
        Map.fetch!(members, "xl/worksheets/sheet2.xml")
      )

      refute Map.has_key?(members, "xl/calcChain.xml")
      refute Map.fetch!(members, "[Content_Types].xml") =~ "calcChain"
      refute Map.fetch!(members, "xl/_rels/workbook.xml.rels") =~ "calcChain"

      assert_all_parts_well_formed!(members)
    end
  end
end
