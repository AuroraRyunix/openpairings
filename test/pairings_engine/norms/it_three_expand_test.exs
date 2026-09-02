defmodule PairingsEngine.Norms.ItThreeExpandTest do
  # async: true - pure, no database; reads the real IT3 template file only.
  use ExUnit.Case, async: true

  alias PairingsEngine.Norms.{Forms, ItThreeExpand, XlsxFill}

  @template File.read!(Forms.template_path(:it3))

  describe "arbiter_cell_ref/2" do
    test "arbiters 1 and 2 land on the template's own spare rows (formerly '3rd/4th deputy')" do
      assert ItThreeExpand.arbiter_cell_ref(1) == {"B66", "B67"}
      assert ItThreeExpand.arbiter_cell_ref(2) == {"B68", "B69"}
    end

    test "arbiter 3 onward lands right after those spare rows (69), two per arbiter" do
      assert ItThreeExpand.arbiter_cell_ref(3) == {"B70", "B71"}
      assert ItThreeExpand.arbiter_cell_ref(4) == {"B72", "B73"}
      assert ItThreeExpand.arbiter_cell_ref(5) == {"B74", "B75"}
    end
  end

  describe "expand/2" do
    test "extra_count 0, 1 or 2 all return the template untouched (they fit in spare rows)" do
      assert ItThreeExpand.expand(@template, 0) == @template
      assert ItThreeExpand.expand(@template, 1) == @template
      assert ItThreeExpand.expand(@template, 2) == @template
    end

    test "extra_count 3+ grows both sheets, and every XML member stays well-formed" do
      expanded = ItThreeExpand.expand(@template, 3)
      refute expanded == @template

      {:ok, entries} = :zip.unzip(expanded, [:memory])

      Enum.each(entries, fn {name, bin} ->
        name = List.to_string(name)

        if String.ends_with?(name, ".xml") do
          # Raises on malformed XML - the assertion is that this doesn't.
          :xmerl_scan.string(:binary.bin_to_list(bin))
        end
      end)
    end

    test "Invulformulier: old row 70 ('his/her (federation)') shifts down and keeps its content" do
      # 2 extra arbiters beyond the 3rd (which is the first one that needs a
      # real new row) => 2 new rows => 1 row of shift.
      expanded = ItThreeExpand.expand(@template, 4)
      {:ok, entries} = :zip.unzip(expanded, [:memory])
      entries = Enum.map(entries, fn {n, b} -> {List.to_string(n), b} end)
      {_, invul} = List.keyfind(entries, "xl/worksheets/sheet2.xml", 0)

      refute invul =~ ~r/<row r="70"[^>]*><c r="A70" t="s"><v>81<\/v>/
      assert invul =~ ~r/<row r="74"[^>]*><c r="A74" t="s"><v>81<\/v>/
      assert invul =~ ~s(<dimension ref="A1:B74"/>)
    end

    test "Certificaat: the CONCATENATE note's cross-sheet reference follows the shift" do
      expanded = ItThreeExpand.expand(@template, 4)
      {:ok, entries} = :zip.unzip(expanded, [:memory])
      entries = Enum.map(entries, fn {n, b} -> {List.to_string(n), b} end)
      {_, cert} = List.keyfind(entries, "xl/worksheets/sheet1.xml", 0)

      # $B$70 legitimately still appears (it's arbiter 3's own id cell now -
      # see the next test) - what must NOT survive is the CONCATENATE note
      # still pointing at the old (pre-shift) row 70.
      refute cert =~
               ~s(CONCATENATE("The organizer must provide this report form to each arbiter who has achieved a norm,  ",Invulformulier!$B$70,)

      assert cert =~
               ~s(CONCATENATE("The organizer must provide this report form to each arbiter who has achieved a norm,  ",Invulformulier!$B$74,)

      assert cert =~ ~s(<dimension ref="A1:J46"/>)
    end

    test "Certificaat: each new arbiter block's formulas reference its own Invulformulier cells" do
      expanded = ItThreeExpand.expand(@template, 4)
      {:ok, entries} = :zip.unzip(expanded, [:memory])
      entries = Enum.map(entries, fn {n, b} -> {List.to_string(n), b} end)
      {_, cert} = List.keyfind(entries, "xl/worksheets/sheet1.xml", 0)

      assert cert =~ "Invulformulier!$B$70"
      assert cert =~ "Invulformulier!$B$71"
      assert cert =~ "Invulformulier!$B$72"
      assert cert =~ "Invulformulier!$B$73"
      assert cert =~ ~s(<mergeCell ref="A40:B40"/>)
      assert cert =~ ~s(<mergeCell ref="C42:J42"/>)
    end

    test "fills round-trip correctly through XlsxFill.fill_from_binary/2 for a genuinely-expanded arbiter" do
      expanded = ItThreeExpand.expand(@template, 3)

      {:ok, binary} =
        XlsxFill.fill_from_binary(expanded, %{
          "Invulformulier" => %{"B70" => 205_494, "B71" => "Cornet, Luc"}
        })

      {:ok, entries} = :zip.unzip(binary, [:memory])
      entries = Enum.map(entries, fn {n, b} -> {List.to_string(n), b} end)
      {_, invul} = List.keyfind(entries, "xl/worksheets/sheet2.xml", 0)

      assert invul =~ "205494"
      assert invul =~ "Cornet, Luc"
    end

    test "fills round-trip correctly for arbiter 1/2 with no expansion at all" do
      {:ok, binary} =
        XlsxFill.fill_from_binary(ItThreeExpand.expand(@template, 2), %{
          "Invulformulier" => %{"B66" => 205_494, "B67" => "Cornet, Luc"}
        })

      {:ok, entries} = :zip.unzip(binary, [:memory])
      entries = Enum.map(entries, fn {n, b} -> {List.to_string(n), b} end)
      {_, invul} = List.keyfind(entries, "xl/worksheets/sheet2.xml", 0)

      assert invul =~ "205494"
      assert invul =~ "Cornet, Luc"
    end

    test "the cap itself still expands" do
      max = Forms.max_extra_arbiters()
      refute ItThreeExpand.expand(@template, max) == @template
    end

    test "above the cap it refuses rather than building the rows" do
      max = Forms.max_extra_arbiters()

      assert_raise ArgumentError, fn -> ItThreeExpand.expand(@template, max + 1) end
      assert_raise ArgumentError, fn -> ItThreeExpand.expand(@template, 100_000_000) end
    end
  end
end
