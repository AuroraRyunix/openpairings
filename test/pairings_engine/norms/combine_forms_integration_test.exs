defmodule PairingsEngine.Norms.CombineFormsIntegrationTest do
  @moduledoc """
  End-to-end checks that `PairingsEngine.Norms.Forms` + `PairingsEngine.Norms.XlsxFill`
  accept the fully in-memory, unpersisted structs produced by
  `PairingsEngine.Norms.Combine.combine/2` and `PairingsEngine.TrfImport.build_structs/1`
  - the two building blocks for the upcoming "combined norms" flow and the
  public no-login /tools page, neither of which touch the database. This is
  Task 3 of that groundwork: confirming Forms needs no adaptation for either
  path.
  """

  use ExUnit.Case, async: true

  alias PairingsEngine.TrfImport
  alias Ainalrami.Trf
  alias PairingsEngine.Norms.{Combine, Forms, XlsxFill}
  alias PairingsEngine.Tournaments.{Tournament, Player}

  # ---------------------------------------------------------------------
  # strict XML well-formedness helper - same technique as
  # test/pairings_engine/norms/xlsx_fill_test.exs's `assert_well_formed_xml!/2`
  # (xmerl_scan is a real, validating XML parser, catching corruption a
  # lenient reader would silently pass through).
  # ---------------------------------------------------------------------

  defp unzip_map(binary) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "combine_forms_test_#{System.unique_integer([:positive])}.xlsx"
      )

    File.write!(tmp, binary)
    {:ok, entries} = :zip.unzip(String.to_charlist(tmp), [:memory])
    File.rm(tmp)
    Map.new(entries, fn {name, bin} -> {List.to_string(name), bin} end)
  end

  defp assert_all_parts_well_formed!(members) do
    Enum.each(members, fn {name, bin} ->
      if String.ends_with?(name, ".xml") or String.ends_with?(name, ".rels") do
        charlist = :erlang.binary_to_list(bin)

        case :xmerl_scan.string(charlist, quiet: true) do
          {_parsed, _rest} ->
            :ok

          other ->
            flunk("#{name}: xmerl_scan did not return a parsed document, got: #{inspect(other)}")
        end
      end
    end)
  end

  # ---------------------------------------------------------------------
  # (a) combined virtual tournament -> IT3
  # ---------------------------------------------------------------------

  describe "IT3 from a Combine.combine/2 virtual tournament" do
    test "the master's name/round_dates/rounds_count drive B3/B12/B11, and player counts/federations union across both tournaments" do
      open =
        %Tournament{
          id: 100,
          name: "Ghent Chess Festival - Open",
          federation: "BEL",
          venue: "City Hall",
          city: "Ghent",
          start_date: "2026-09-01",
          end_date: "2026-09-05",
          rounds_count: 9,
          round_dates: [
            "2026-09-01",
            "2026-09-02",
            "2026-09-02",
            "2026-09-03",
            "2026-09-03",
            "2026-09-04",
            "2026-09-04",
            "2026-09-05",
            "2026-09-05"
          ],
          officials: %{"pairing_mode" => "computerized"}
        }

      youth = %Tournament{id: 200, name: "Ghent Chess Festival - Youth", federation: "BEL"}

      open_players = [
        %Player{name: "Alpha, One", federation: "BEL", fide_id: 1, fide_rating: 2100},
        %Player{name: "Bravo, Two", federation: "NED", fide_id: 2, fide_rating: 2000}
      ]

      youth_players = [
        %Player{name: "Charlie, Three", federation: "GER", fide_id: 3, fide_rating: 0},
        %Player{name: "Delta, Four", federation: "BEL", fide_id: 4, fide_rating: 0}
      ]

      assert {:ok, {virtual_tournament, virtual_players}} =
               Combine.combine([{open, open_players}, {youth, youth_players}], 0)

      assert virtual_tournament.name == "Ghent Chess Festival - Open Festival"
      assert length(virtual_players) == 4

      fills = Forms.it3_fills(virtual_tournament, virtual_players)
      invulformulier = fills["Invulformulier"]

      assert invulformulier["B3"] == "Ghent Chess Festival - Open Festival"
      assert invulformulier["B11"] == 9
      # 9 rounds over 5 distinct days, two double-round days each after the
      # first - same chunk-by-consecutive-equal-date rule as forms_test.exs.
      assert invulformulier["B12"] == "1-2-2-2-2"

      # Rated total: Alpha (2100) + Bravo (2000) = 2 (Charlie/Delta are both
      # unrated, fide_rating 0); their federations BEL+NED = 2 distinct;
      # BEL (the host) is just Alpha = 1.
      assert invulformulier["B27"] == 2
      assert invulformulier["B28"] == 2
      assert invulformulier["B29"] == 1

      assert {:ok, binary} = XlsxFill.fill(Forms.template_path(:it3), fills)
      members = unzip_map(binary)
      assert_all_parts_well_formed!(members)

      sheet_xml = Map.fetch!(members, "xl/worksheets/sheet2.xml")

      assert sheet_xml =~
               ~r/<c r="B3"[^>]*t="inlineStr"><is><t xml:space="preserve">Ghent Chess Festival - Open Festival<\/t><\/is><\/c>/
    end
  end

  # ---------------------------------------------------------------------
  # (b) TrfImport.build_structs/1 -> FA1 / IA1
  # ---------------------------------------------------------------------

  describe "FA1/IA1 from TrfImport.build_structs/1 structs" do
    defp trf_text do
      Trf.serialize(%{
        tournament: %{
          name: "Uploaded TRF Open",
          city: "Leuven",
          federation: "BEL",
          start_date: "2026-10-01",
          end_date: "2026-10-03",
          type: "swiss",
          chief_arbiter: "Jane Arbiter",
          round_dates: ["2026-10-01", "2026-10-02", "2026-10-03"]
        },
        players: [
          %{
            rank: 1,
            name: "Player, One",
            fide_rating: 2100,
            title: "IM",
            federation: "BEL",
            points: 1.5,
            games: [
              %{opponent_rank: 2, colour: "w", result: "1"},
              %{opponent_rank: 2, colour: "w", result: "0"},
              %{opponent_rank: 2, colour: "w", result: "="}
            ]
          },
          %{
            rank: 2,
            name: "Player, Two",
            fide_rating: 0,
            federation: "NED",
            points: 1.5,
            games: [
              %{opponent_rank: 1, colour: "b", result: "0"},
              %{opponent_rank: 1, colour: "b", result: "1"},
              %{opponent_rank: 1, colour: "b", result: "="}
            ]
          }
        ]
      })
    end

    test "player count, rated count and federations-represented all come from the uploaded structs" do
      assert {:ok, {tournament, players}} = TrfImport.build_structs(trf_text())

      candidate = %{
        "last_name" => "Smith",
        "first_name" => "Alice",
        "fide_id" => "1234567",
        "federation" => "BEL"
      }

      fa1_fills = Forms.fa1_fills(tournament, players, candidate)
      ia1_fills = Forms.ia1_fills(tournament, players, candidate)
      assert fa1_fills == ia1_fills

      invulformulier = fa1_fills["Invulformulier"]
      assert invulformulier["B7"] == "Uploaded TRF Open"
      assert invulformulier["B13"] == 2
      assert invulformulier["B14"] == 1
      assert invulformulier["B15"] == 2
      assert invulformulier["B12"] == 3

      assert {:ok, fa1_binary} = XlsxFill.fill(Forms.template_path(:fa1), fa1_fills)
      fa1_members = unzip_map(fa1_binary)
      assert_all_parts_well_formed!(fa1_members)

      assert {:ok, ia1_binary} = XlsxFill.fill(Forms.template_path(:ia1), ia1_fills)
      ia1_members = unzip_map(ia1_binary)
      assert_all_parts_well_formed!(ia1_members)

      sheet_xml = Map.fetch!(fa1_members, "xl/worksheets/sheet1.xml")

      assert sheet_xml =~
               ~r/<c r="B7"[^>]*t="inlineStr"><is><t xml:space="preserve">Uploaded TRF Open<\/t><\/is><\/c>/
    end
  end
end
