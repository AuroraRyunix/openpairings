defmodule PairingsEngine.TrfCompleteReportTest do
  @moduledoc """
  VCL4THP Q217 - the final TRF reflects what happened - and Q112-Q115, the
  Correction PIBE:

    * a result corrected after a later round was paired waits for the
      arbiter's confirmation, keeps the result it replaced, and is a
      `### Correction @ Round r: a-b: old => new` line in every TRF26 file
      but the one sent for rating;
    * national ratings that rank somebody are National Rating Support
      records with their `172`;
    * extra points are a `299` with its round;
    * a prohibition added after rounds were paired is a `260` from the
      round it was added for.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Pairing, PostponedGames, Repo, ResultCorrections, TrfExport, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  defp tournament(attrs \\ []) do
    Repo.insert!(
      struct(
        Tournament,
        Map.merge(
          %{
            name: "Club championship",
            type: "swiss",
            federation: "BEL",
            rounds_count: 4,
            tiebreaks: ~w(BH SB),
            round_dates: ~w(2026-09-01 2026-09-08 2026-09-15 2026-09-22)
          },
          Map.new(attrs)
        )
      )
    )
  end

  defp players(t, specs) do
    for {name, fide, national} <- specs, into: %{} do
      {:ok, p} =
        Tournaments.create_player(t.id, %{
          tournament_id: t.id,
          name: name,
          fide_rating: fide,
          national_rating: national,
          national_id: "#{1000 + fide + national}"
        })

      {name, p}
    end
  end

  @four [{"Alice", 2000, 0}, {"Bob", 1900, 0}, {"Carol", 1800, 0}, {"Dave", 1700, 0}]

  defp play!(t) do
    {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))
    round = Tournaments.get_round(t.id, round.number)

    for p <- round.pairings, p.black_player_id do
      {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
    end

    Tournaments.get_round(t.id, round.number)
  end

  defp rank(t, player_id),
    do: Enum.find(Tournaments.list_players(t.id), &(&1.id == player_id)).pairing_number

  describe "a result corrected after a later round was paired (Correction PIBE)" do
    setup do
      t = tournament()
      players(t, @four)
      r1 = play!(t)
      _r2 = play!(t)
      [board | _] = Enum.filter(r1.pairings, & &1.black_player_id)
      %{t: t, board: Repo.reload!(board)}
    end

    test "waits for the arbiter's confirmation (Level 3, Q115)", %{board: board} do
      assert ResultCorrections.correction?(board, "0-1")

      assert {:error, {:needs_acknowledgement, [:result_correction]}} =
               Tournaments.update_pairing_result(board, "0-1")

      assert Repo.reload!(board).result == "1-0"
    end

    test "once confirmed, the board keeps the result it replaced", %{board: board} do
      assert {:ok, updated} =
               Tournaments.update_pairing_result(board, "0-1", acknowledged: [:result_correction])

      assert updated.result == "0-1"
      assert updated.corrected_from == "1-0"

      # A second correction keeps the ORIGINAL result; putting it back
      # leaves no correction at all.
      {:ok, again} =
        Tournaments.update_pairing_result(updated, "1/2-1/2", acknowledged: [:result_correction])

      assert again.corrected_from == "1-0"

      {:ok, back} =
        Tournaments.update_pairing_result(again, "1-0", acknowledged: [:result_correction])

      assert back.corrected_from == nil
    end

    test "is a ### Correction line in a TRF26 file, never in the file sent for rating", %{
      t: t,
      board: board
    } do
      {:ok, _} =
        Tournaments.update_pairing_result(board, "0-1", acknowledged: [:result_correction])

      w = rank(t, board.white_player_id)
      b = rank(t, board.black_player_id)

      assert {:ok, copy} = TrfExport.export(Repo.reload!(t))
      assert copy =~ "\r\n### Correction @ Round 1: #{w}-#{b}: 1-0 => 0-1\r\n"

      assert {:ok, rating} = TrfExport.export(Repo.reload!(t), nil, for: :rating)
      refute rating =~ "###"

      # A file of round 2 only does not carry round 1's correction.
      assert {:ok, round2} = TrfExport.export(Repo.reload!(t), "2")
      refute round2 =~ "Correction"
    end

    test "clearing a result remembers it, and the result entered next is a correction", %{
      board: board
    } do
      {:ok, cleared} = Tournaments.update_pairing_result(board, "")
      assert cleared.corrected_from == "1-0"

      assert {:error, {:needs_acknowledgement, [:result_correction]}} =
               Tournaments.update_pairing_result(cleared, "0-1")
    end

    test "is in the registry of warnings that wait for the arbiter" do
      assert :result_correction in PostponedGames.acknowledgement_ids()
    end
  end

  describe "what is not a correction" do
    test "a result in the latest round, and a first result in an older one" do
      t = tournament()
      players(t, @four)
      {:ok, r1} = Pairing.pair_next_round(Repo.reload!(t))
      [b1, b2] = Tournaments.get_round(t.id, r1.number).pairings

      {:ok, b1} = Tournaments.update_pairing_result(b1, "1-0")
      # Round 1 is the latest round: changing it is not a correction.
      refute ResultCorrections.correction?(b1, "0-1")
      {:ok, b1} = Tournaments.update_pairing_result(b1, "0-1")
      assert b1.corrected_from == nil

      {:ok, b2} = Tournaments.update_pairing_result(b2, "1-0")
      {:ok, _} = Pairing.pair_next_round(Repo.reload!(t))

      # Round 1 is closed now. A board that never had a result: entering
      # one is not a correction.
      assert ResultCorrections.closed?(b2)
      refute ResultCorrections.correction?(%{b2 | corrected_from: nil, result: ""}, "1-0")
      # A postponed game given its result is not one either (Q163's own).
      refute ResultCorrections.correction?(%{b2 | result: "*"}, "1-0")
    end
  end

  describe "National Rating Support (172 and the federation's records)" do
    test "a player ranked by a national rating brings 172 and the NRS records" do
      t = tournament()

      ps =
        players(t, [
          {"Alice", 2000, 1950},
          {"Bob", 1900, 0},
          {"Carol", 0, 1600},
          {"Dave", 1700, 0}
        ])

      play!(t)

      for text <- [
            elem(TrfExport.export(Repo.reload!(t)), 1),
            elem(TrfExport.export(Repo.reload!(t), nil, for: :rating), 1)
          ] do
        lines = String.split(text, "\r\n")
        assert "172 BEL FIDON" in lines

        carol = rank(t, ps["Carol"].id)

        i =
          Enum.find_index(
            lines,
            &(String.starts_with?(&1, "001") and
                String.slice(&1, 4, 4) == String.pad_leading("#{carol}", 4))
          )

        nrs = Enum.at(lines, i + 1)
        assert String.slice(nrs, 0, 3) == "BEL"
        assert String.slice(nrs, 4, 4) == String.pad_leading("#{carol}", 4)
        assert String.slice(nrs, 48, 4) == "1600"
        assert String.slice(nrs, 57, 11) |> String.trim() == ps["Carol"].national_id

        # Alice's national rating is a record too; Bob has none.
        assert Enum.count(lines, &String.starts_with?(&1, "BEL ")) == 2
        # 172 sits with the header records, before the players.
        assert Enum.find_index(lines, &(&1 == "172 BEL FIDON")) <
                 Enum.find_index(lines, &String.starts_with?(&1, "001"))
      end
    end

    test "nothing when every player is ranked by a FIDE rating" do
      t = tournament()

      players(t, [
        {"Alice", 2000, 1950},
        {"Bob", 1900, 0},
        {"Carol", 1800, 1600},
        {"Dave", 1700, 0}
      ])

      play!(t)

      {:ok, text} = TrfExport.export(Repo.reload!(t))
      refute text =~ "\r\n172 "
      refute text =~ "\r\nBEL "
    end

    test "the file still reads back" do
      t = tournament()
      players(t, [{"Alice", 2000, 0}, {"Bob", 0, 1500}, {"Carol", 1800, 0}, {"Dave", 1700, 0}])
      play!(t)

      {:ok, text} = TrfExport.export(Repo.reload!(t))
      assert text =~ "172 BEL FIDON"
      parsed = Ainalrami.Trf.parse(text)
      assert length(parsed.players) == 4
    end
  end

  describe "extra points (299) carry their round" do
    test "a counted handicap is 000, before round 1" do
      t = tournament(count_extra_points: true)
      ps = players(t, @four)
      {:ok, _} = Tournaments.update_player(ps["Bob"], %{"extra_points" => 1.5})
      play!(t)

      {:ok, text} = TrfExport.export(Repo.reload!(t))
      [line] = text |> String.split("\r\n") |> Enum.filter(&String.starts_with?(&1, "299"))
      assert String.slice(line, 13, 4) == " 1.5"
      assert String.slice(line, 19, 3) == "000"
      assert String.slice(line, 23, 4) |> String.trim() == "#{rank(t, ps["Bob"].id)}"
    end

    test "acceleration-mode points kept in the standings are 999, the final standings only" do
      t = tournament(count_extra_points: true, extra_points_mode: "acceleration")
      ps = players(t, @four)
      {:ok, _} = Tournaments.update_player(ps["Bob"], %{"extra_points" => 1.0})
      play!(t)

      {:ok, text} = TrfExport.export(Repo.reload!(t))
      [line] = text |> String.split("\r\n") |> Enum.filter(&String.starts_with?(&1, "299"))
      assert String.slice(line, 19, 3) == "999"
    end
  end

  describe "a prohibition added after rounds were paired (260)" do
    test "holds from the round it was added for" do
      t = tournament()
      ps = players(t, @four)
      {:ok, early} = Tournaments.add_forbidden_pairing(t, ps["Alice"].id, ps["Dave"].id)
      assert early.from_round == nil
      play!(t)
      {:ok, late} = Tournaments.add_forbidden_pairing(t, ps["Bob"].id, ps["Carol"].id)
      assert late.from_round == 2

      {:ok, text} = TrfExport.export(Repo.reload!(t))
      groups = Ainalrami.Trf.parse(text).tournament[:forbidden_pairs]
      a = rank(t, ps["Alice"].id)
      d = rank(t, ps["Dave"].id)
      b = rank(t, ps["Bob"].id)
      c = rank(t, ps["Carol"].id)

      assert {Enum.sort([a, d]), 1} in Enum.map(groups, fn {ids, first, _} ->
               {Enum.sort(ids), first}
             end)

      assert {Enum.sort([b, c]), 2} in Enum.map(groups, fn {ids, first, _} ->
               {Enum.sort(ids), first}
             end)

      # The engine's spelling has no rounds: both pairs stay plain there.
      {:ok, engine} = TrfExport.export(Repo.reload!(t), nil, dialect: :engine)
      refute engine =~ "\r\n260"
    end
  end
end
