defmodule PairingsEngine.TrfImportFutureByeTest do
  @moduledoc """
  A bye a TRF records for a round nobody has paired yet - a column past the
  last paired round (`0000 - H`) or a TRF26 `240` - is the arbiter's
  "this player is not playing that round". Imported, it must keep the
  player out of that round's pairing exactly as the same bye entered on the
  player before pairing does, and be scored once: as the bye, not as the
  bye and a game.
  """

  # async: false - whole-tournament writes in a real transaction, as the
  # other import tests.
  use PairingsEngine.DataCase, async: false

  alias Ainalrami.Trf
  alias PairingsEngine.{Pairing, Repo, Standings, TrfExport, TrfImport, Tournaments}
  alias PairingsEngine.Accounts.{Scope, User}

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp game(opponent, colour, result),
    do: %{opponent_rank: opponent, colour: colour, result: result}

  defp nobody(result), do: %{opponent_rank: nil, colour: nil, result: result}

  @names ~w(Alpha Bravo Charlie Delta Echo Foxtrot)

  # Six players, round 1 played. Round 2 not paired, but Charlie (3) has a
  # full-point bye, Echo (5) a half-point and Foxtrot (6) a zero-point one
  # recorded for it.
  defp file(dialect, tournament \\ %{}) do
    games = %{
      1 => [game(4, "w", "1")],
      2 => [game(5, "w", "=")],
      3 => [game(6, "w", "0"), nobody("F")],
      4 => [game(1, "b", "0")],
      5 => [game(2, "b", "="), nobody("H")],
      6 => [game(3, "b", "1"), nobody("Z")]
    }

    players =
      for {rank, gs} <- Enum.sort(games) do
        %{
          rank: rank,
          name: "#{Enum.at(@names, rank - 1)}, Player",
          points: Enum.reduce(gs, 0.0, &(&2 + Trf.points_for_game(&1))),
          games: gs
        }
      end

    Trf.serialize(
      %{
        tournament:
          Map.merge(%{name: "Future byes", type: "swiss", number_of_rounds: 5}, tournament),
        players: players
      },
      dialect: dialect
    )
  end

  # The engines' convention, which a TRF26 file follows too once read: a
  # bye recorded ahead is credited in the total up front.
  defp import!(text) do
    assert {:ok, tournament, []} = TrfImport.import_text(text, user_scope())
    tournament
  end

  defp by_name(tournament),
    do: Map.new(Tournaments.list_players(tournament.id), &{hd(String.split(&1.name, ",")), &1})

  defp round_2_byes(tournament) do
    tournament.id
    |> Tournaments.list_byes_for_round(2)
    |> Map.new(&{hd(String.split(&1.player.name, ",")), &1.type})
  end

  @expected %{
    "Charlie" => "full-point",
    "Echo" => "requested-half",
    "Foxtrot" => "requested-zero"
  }

  for dialect <- [:engine, :trf26] do
    test "#{dialect}: a future-round bye keeps the player out of that round, scored once" do
      text = file(unquote(dialect))

      if unquote(dialect) == :trf26,
        do: assert(text =~ "240 H 002"),
        else: assert(text =~ "0000 - H")

      tournament = import!(text)
      assert Pairing.paired_rounds_count(tournament.id) == 1
      assert round_2_byes(tournament) == @expected

      players = by_name(tournament)
      assert {:ok, _round} = Pairing.pair_next_round(Repo.reload!(tournament))

      [round] =
        Repo.all(
          from r in PairingsEngine.Tournaments.Round,
            where: r.tournament_id == ^tournament.id and r.number == 2,
            preload: :pairings
        )

      seated =
        round.pairings
        |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
        |> Enum.reject(&is_nil/1)

      for name <- ~w(Charlie Echo Foxtrot), do: refute(players[name].id in seated, name)
      assert length(seated) == 3

      # One row each, the type the file gave, and the score counts it once.
      assert round_2_byes(tournament) == @expected

      points = Standings.points_by_player(Repo.reload!(tournament))
      assert points[players["Charlie"].id] == 1.0
      assert points[players["Echo"].id] == 1.0
      assert points[players["Foxtrot"].id] == 1.0
    end
  end

  test "the confirm step lists the byes it kept" do
    assert {:ok, report} = TrfImport.review(file(:engine))

    assert %{count: 3, rounds: [2]} =
             Enum.find(report.adjustments, &(&1.code == :future_byes_kept))
  end

  test "re-export writes the byes back, and re-import is idempotent" do
    # The file has no round dates, and FIDE's report needs them.
    tournament =
      file(:trf26)
      |> import!()
      |> Ecto.Changeset.change(round_dates: for(n <- 1..5, do: "2026-03-0#{n}"))
      |> Repo.update!()

    assert {:ok, once} = TrfExport.export(tournament)
    assert once =~ "240 H 002"
    assert once =~ "240 Z 002"
    assert once =~ "240 F 002"

    again = import!(once)
    assert round_2_byes(again) == @expected
    assert by_name(again)["Echo"].absent_rounds == "2"
    assert {:ok, twice} = TrfExport.export(Repo.reload!(again))
    # The second file gains the start and end dates the first one's round
    # dates gave the re-imported tournament; the rest is the same, byte for byte.
    assert once == String.replace(twice, ~r/^0[45]2 .*
/m, "")
  end

  test "a round robin cannot leave a player out of a round: the bye is refused, and said" do
    text = file(:trf26, %{type_code: "FIDE_ROUNDROBIN"})
    assert {:ok, report} = TrfImport.review(text)

    assert %{count: 3, rounds: [2]} =
             Enum.find(report.adjustments, &(&1.code == :future_byes_dropped))

    tournament = import!(text)
    assert tournament.pairing_system == "round_robin"
    assert round_2_byes(tournament) == %{}
    assert Enum.all?(Tournaments.list_players(tournament.id), &(&1.absent_rounds in [nil, ""]))
  end

  test "a team event leaves the player out of the line-up, as an absence entered on the player does" do
    {t, _} =
      PairingsEngine.TeamFixtures.team_swiss(
        [{"A", [2200, 2100]}, {"B", [2150, 2050]}, {"C", [2000, 1950]}, {"D", [1900, 1850]}],
        start_date: "2026-03-01",
        end_date: "2026-03-05",
        round_dates: for(n <- 1..5, do: "2026-03-0#{n}")
      )

    round = PairingsEngine.TeamFixtures.pair_next!(t)

    for p <- Repo.preload(round, :pairings).pairings,
        do: {:ok, _} = Tournaments.update_pairing_result(p, "1-0")

    a1 = Enum.find(Tournaments.list_players(t.id), &(&1.name == "A 1"))

    Repo.insert_all("byes", [
      %{tournament_id: t.id, player_id: a1.id, round: 2, type: "requested-half"}
    ])

    assert {:ok, text} = TrfExport.export(Repo.reload!(t))
    assert text =~ "240 H 002"

    assert {:ok, imported, _warnings} = TrfImport.import_text(text, user_scope())
    assert Pairing.paired_rounds_count(imported.id) == 1
    a1 = Enum.find(Tournaments.list_players(imported.id), &(&1.name == "A 1"))
    assert a1.absent_rounds == "2"

    round = PairingsEngine.TeamFixtures.pair_next!(imported)
    seated = Repo.preload(round, :pairings).pairings
    assert seated != []
    refute Enum.any?(seated, &(a1.id in [&1.white_player_id, &1.black_player_id]))

    assert [%{type: "requested-half"}] =
             Tournaments.list_byes_for_round(imported.id, 2)
             |> Enum.filter(&(&1.player_id == a1.id))
  end
end
