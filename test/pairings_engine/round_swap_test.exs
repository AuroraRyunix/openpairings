defmodule PairingsEngine.RoundSwapTest do
  @moduledoc """
  Two rounds of a round robin played in each other's place
  (`PairingsEngine.RoundSwap`, `tournaments.rr_round_map`).
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{
    PairingRationale,
    Repo,
    RoundRobin,
    RoundSwap,
    Tournaments,
    TournamentExport,
    TournamentImport,
    TrfExport,
    TrfImport
  }

  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.Tournaments.{Match, Round, Tournament}

  @moduletag :capture_log

  defp individual_rr(n, attrs \\ []) do
    t =
      Repo.insert!(
        struct(
          Tournament,
          Keyword.merge(
            [
              name: "RR",
              type: "roundrobin",
              pairing_system: "round_robin",
              rounds_count: 9,
              rr_cycles: 1,
              fide_compliance_lost_round: 0
            ],
            attrs
          )
        )
      )

    for i <- 1..n do
      {:ok, _} =
        Tournaments.create_player(t.id, %{"name" => "P#{i}", "fide_rating" => "#{2100 - i}"})
    end

    t
  end

  defp paired_rr(n, attrs \\ []) do
    t = individual_rr(n, attrs)
    {:ok, _} = RoundRobin.pair_all_rounds(t)
    Repo.reload!(t)
  end

  # `{white_number, black_number}` per board of round `number`, sorted -
  # pairing numbers, so a round compares with `RoundRobin.schedule/4`.
  defp boards(t, number) do
    round = Tournaments.get_round(t.id, number)

    round.pairings
    |> Enum.filter(&(&1.white_player && &1.black_player))
    |> Enum.map(&{&1.white_player.pairing_number, &1.black_player.pairing_number})
    |> Enum.sort()
  end

  defp table(n, cycles, table_round, opts \\ []) do
    {:ok, entries} = RoundRobin.schedule(n, cycles, table_round, opts)
    for({:pairing, w, b} <- entries, do: {w, b}) |> Enum.sort()
  end

  defp score_round(t, number) do
    for p <- Tournaments.get_round(t.id, number).pairings,
        p.white_player_id && p.black_player_id do
      {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
    end
  end

  test "two result-free rounds trade their boards; the round numbers stay the evenings" do
    t = paired_rr(6, round_dates: ~w(2026-10-01 2026-10-08 2026-10-15 2026-10-22 2026-10-29))
    date_4 = Tournaments.get_round(t.id, 4).date
    date_5 = Tournaments.get_round(t.id, 5).date

    assert {:ok, t} = RoundSwap.swap(t, 4, 5)
    assert t.rr_round_map == [1, 2, 3, 5, 4]

    assert boards(t, 4) == table(6, 1, 5)
    assert boards(t, 5) == table(6, 1, 4)
    assert RoundRobin.table_round_number(t, 4) == 5
    assert RoundRobin.table_round_number(t, 5) == 4
    assert RoundRobin.table_round_number(t, 1) == 1

    assert Tournaments.get_round(t.id, 4).date == date_4
    assert Tournaments.get_round(t.id, 5).date == date_5
  end

  test "refused when either round has a result, naming the round" do
    t = paired_rr(4)
    score_round(t, 2)

    assert {:error, message} = RoundSwap.swap(t, 2, 3)
    assert message =~ "Round 2"
    assert {:error, message} = RoundSwap.swap(t, 3, 2)
    assert message =~ "Round 2"
    assert Repo.reload!(t).rr_round_map == nil
  end

  test "check/3 answers what swap/3 would, and changes nothing" do
    t = paired_rr(4)
    assert :ok = RoundSwap.check(t, 1, 3)
    assert Repo.reload!(t).rr_round_map == nil

    score_round(t, 2)
    assert {:error, message} = RoundSwap.check(t, 2, 3)
    assert {:error, ^message} = RoundSwap.swap(t, 2, 3)
    assert {:error, _} = RoundSwap.check(t, 2, 2)
  end

  test "refused for a postponed game" do
    t = paired_rr(4)
    [p | _] = Tournaments.get_round(t.id, 3).pairings
    {:ok, _} = Tournaments.update_pairing_result(p, "*")

    assert {:error, message} = RoundSwap.swap(t, 1, 3)
    assert message =~ "Round 3"
  end

  test "refused before the schedule exists, for the same round twice, and out of range" do
    t = individual_rr(4)
    assert {:error, _} = RoundSwap.swap(t, 1, 2)

    t = paired_rr(4)
    assert {:error, _} = RoundSwap.swap(t, 2, 2)
    assert {:error, _} = RoundSwap.swap(t, 2, 4)
  end

  test "refused in match format" do
    t = paired_rr(4, rr_match_format: true)
    assert {:error, message} = RoundSwap.swap(t, 1, 3)
    assert message =~ "match format"
  end

  test "swapping back returns to the table's own order" do
    t = paired_rr(5)
    before = for r <- 1..5, do: boards(t, r)

    {:ok, t} = RoundSwap.swap(t, 2, 5)
    {:ok, t} = RoundSwap.swap(t, 5, 2)

    assert t.rr_round_map == nil
    assert for(r <- 1..5, do: boards(t, r)) == before
  end

  test "the odd field's sitting-out bye moves with its round" do
    t = paired_rr(5)

    bye_in = fn t, number ->
      from(b in "byes",
        where: b.tournament_id == ^t.id and b.round == ^number,
        select: b.player_id
      )
      |> Repo.all()
    end

    bye_2 = bye_in.(t, 2)
    bye_4 = bye_in.(t, 4)
    assert length(bye_2) == 1

    {:ok, t} = RoundSwap.swap(t, 2, 4)
    assert bye_in.(t, 2) == bye_4
    assert bye_in.(t, 4) == bye_2
  end

  test "the explanation still names the Berger round it is" do
    t = paired_rr(6)
    {:ok, t} = RoundSwap.swap(t, 2, 5)

    rationale = PairingRationale.for_round(t, 2)
    assert rationale.berger.cycle == 1
    assert rationale.berger.cycle_round == 5
    assert rationale.berger.played_as == 2

    assert PairingRationale.for_round(t, 5).berger.cycle_round == 2
  end

  test "a swap across cycles keeps each game's colours as its table round gives them" do
    t = paired_rr(4, rr_cycles: 3)
    assert t.rounds_count == 9

    {:ok, t} = RoundSwap.swap(t, 2, 8)
    assert boards(t, 2) == table(4, 3, 8)
    assert boards(t, 8) == table(4, 3, 2)

    rationale = PairingRationale.for_round(t, 2)
    assert rationale.berger.cycle == 3
    assert rationale.berger.cycle_round == 2
  end

  test "swapped rounds that are not paired yet are paired from the swapped table rounds" do
    t = individual_rr(4)
    # Round 1 by the table, the rest left for later.
    {:ok, _} = PairingsEngine.Pairing.pair_next_round(t)
    t = Repo.reload!(t)

    {:ok, t} = RoundSwap.swap(t, 2, 3)
    {:ok, _} = RoundRobin.pair_all_rounds(t)
    t = Repo.reload!(t)

    assert boards(t, 2) == table(4, 1, 3)
    assert boards(t, 3) == table(4, 1, 2)
  end

  test "on top of FIDE's reversed last two rounds, never instead of them" do
    t = paired_rr(6, rr_cycles: 2, rr_reverse_last_two: true)
    # Schedule rounds 4 and 5 are the reversed table's (table rounds 5 and
    # 4); swapping played rounds 1 and 4 brings schedule round 4 forward.
    {:ok, t} = RoundSwap.swap(t, 1, 4)

    assert boards(t, 1) == table(6, 2, 4, reverse_last_two?: true)
    assert boards(t, 1) == table(6, 2, 5)
    assert boards(t, 4) == table(6, 2, 1, reverse_last_two?: true)

    rationale = PairingRationale.for_round(t, 1)
    assert rationale.berger.cycle_round == 5
  end

  test "the app's own export carries the round map across" do
    user =
      Repo.insert!(%User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    t = paired_rr(4)
    {:ok, t} = RoundSwap.swap(t, 1, 3)

    envelope = TournamentExport.export_tournament(t)
    assert {:ok, [imported]} = TournamentImport.import(envelope, Scope.for_user(user))
    imported = Repo.reload!(imported)

    assert imported.rr_round_map == [3, 2, 1]
    assert boards(imported, 1) == boards(t, 1)
  end

  test "the TRF writes the rounds in playing order and reads back without trouble" do
    t =
      paired_rr(4,
        start_date: "2026-10-01",
        end_date: "2026-10-03",
        round_dates: ~w(2026-10-01 2026-10-02 2026-10-03)
      )

    {:ok, t} = RoundSwap.swap(t, 1, 3)
    for r <- 1..3, do: score_round(t, r)

    {:ok, text} = TrfExport.export(Repo.reload!(t))
    assert {:ok, imported, _warnings} = TrfImport.import_text(text)
    assert imported.pairing_system == "round_robin"
  end

  test "a team round robin swaps its matches" do
    {t, _} =
      team_round_robin(
        [{"A", [2000, 1990]}, {"B", [1900, 1890]}, {"C", [1800, 1790]}, {"D", [1700, 1690]}],
        fide_compliance_lost_round: 0
      )

    t = pair_all!(t)

    matches = fn t, number ->
      round = Repo.one!(from r in Round, where: r.tournament_id == ^t.id and r.number == ^number)

      from(m in Match, where: m.round_id == ^round.id, select: {m.team_a_id, m.team_b_id})
      |> Repo.all()
      |> Enum.sort()
    end

    m1 = matches.(t, 1)
    m3 = matches.(t, 3)

    assert {:ok, t} = RoundSwap.swap(t, 1, 3)
    assert matches.(t, 1) == m3
    assert matches.(t, 3) == m1
    assert t.rr_round_map == [3, 2, 1]
  end

  # A team's line-ups are built for the round number they were paired in:
  # A 1 is absent from round 1, so round 1 seats the reserve A 3 and round
  # 3 seats A 1. Swapping the two would put A 1 at a board in round 1.
  test "a team round robin refuses to move a line-up into a round a seated player cannot play" do
    {t, _} =
      team_round_robin(
        [
          {"A", [2000, 1990, 1980]},
          {"B", [1900, 1890]},
          {"C", [1800, 1790]},
          {"D", [1700, 1690]}
        ],
        fide_compliance_lost_round: 0
      )

    a1 = Enum.find(Tournaments.list_players(t.id), &(&1.name == "A 1"))
    {:ok, _} = Tournaments.update_player(a1, %{"absent_rounds" => "1"})
    t = pair_all!(t)

    assert {:error, message} = RoundSwap.swap(t, 1, 3)
    assert message =~ "A 1"
    assert Repo.reload!(t).rr_round_map == nil

    # Rounds 2 and 3 both seat A 1, who can play either.
    assert {:ok, _} = RoundSwap.swap(t, 2, 3)
  end
end
