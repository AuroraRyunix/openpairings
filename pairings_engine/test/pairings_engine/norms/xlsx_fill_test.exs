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
    tmp = Path.join(System.tmp_dir!(), "xlsx_fill_test_#{System.unique_integer([:positive])}.xlsx")
    File.write!(tmp, binary)

    {:ok, entries} = :zip.unzip(String.to_charlist(tmp), [:memory])
    File.rm(tmp)

    Map.new(entries, fn {name, bin} -> {List.to_string(name), bin} end)
  end

  defp unzip_template_map(path) do
    {:ok, entries} = :zip.unzip(String.to_charlist(path), [:memory])
    Map.new(entries, fn {name, bin} -> {List.to_string(name), bin} end)
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

      # B7 keeps its original style attribute (s="12") and gets a bare
      # numeric Excel-serial <v> for the date.
      expected_serial = Date.diff(~D[2026-07-12], ~D[1899-12-30])
      assert sheet_xml =~ ~r/<c r="B7" s="12"><v>#{expected_serial}<\/v><\/c>/
    end

    test "refuses to overwrite formula cells and leaves the archive untouched" do
      assert {:error, {:formula_cell, "B30"}} =
               XlsxFill.fill(@it3, %{"Invulformulier" => %{"B30" => 999}})
    end

    test "untouched zip members are byte-identical to the template" do
      template_members = unzip_template_map(@it3)

      {:ok, binary} =
        XlsxFill.fill(@it3, %{"Invulformulier" => %{"B3" => "Test Open 2026"}})

      filled_members = unzip_map(binary)

      # sheet2.xml (Invulformulier) gets the actual fill; sheet1.xml
      # (Certificaat, 100% formulas) and sheet2.xml's own formula cells
      # (B30 etc.) both get their stale cached `<v>` stripped so every
      # reader is forced to recompute rather than trust a cache baked in
      # when the template was last saved unfilled; workbook.xml gains
      # fullCalcOnLoad.
      changed =
        MapSet.new(["xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml", "xl/workbook.xml"])

      assert map_size(template_members) == map_size(filled_members)

      Enum.each(template_members, fn {name, bin} ->
        if not MapSet.member?(changed, name) do
          assert bin == Map.fetch!(filled_members, name), "expected #{name} to be byte-identical"
        end
      end)
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
      # last saved unfilled in Excel) — reproduces the reported bug where
      # the Certificaat sheet displayed blank even though Invulformulier had
      # correct data, because non-recalculating readers just show the cache.
      template_members = unzip_template_map(@it3)
      original_certificaat = Map.fetch!(template_members, "xl/worksheets/sheet1.xml")
      assert original_certificaat =~ ~r/<c r="A4" s="39" t="str"><f>[^<]*<\/f><v\/><\/c>/

      {:ok, binary} =
        XlsxFill.fill(@it3, %{"Invulformulier" => %{"B1" => "FIDE"}})

      members = unzip_map(binary)
      certificaat = Map.fetch!(members, "xl/worksheets/sheet1.xml")

      # <f> survives, <v> and the now-meaningless cached-type t="str" are gone.
      assert certificaat =~ ~r/<c r="A4" s="39"><f>[^<]*<\/f><\/c>/
      refute certificaat =~ ~r/<c r="A4"[^>]*><f>[^<]*<\/f><v/

      # B23 shipped with a cached numeric `0` (`<v>0<\/v>`) — also stripped.
      assert Map.fetch!(template_members, "xl/worksheets/sheet1.xml") =~
               ~r/<c r="B23" s="25"><f>[^<]*<\/f><v>0<\/v><\/c>/

      assert certificaat =~ ~r/<c r="B23" s="25"><f>[^<]*<\/f><\/c>/
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
      assert sheet_xml =~ ~r/<c r="B8" s="11"><v>#{expected_serial}<\/v><\/c>/
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
end
