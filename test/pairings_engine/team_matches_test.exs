defmodule PairingsEngine.TeamMatchesTest do
  @moduledoc """
  What an arbiter does to a paired team match: forfeit it by decision (and
  take the decision back), and put a board added by hand into it.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{
    Repo,
    TeamMatches,
    TeamRounds,
    TeamStandings,
    TeamSwiss,
    TournamentExport,
    TournamentImport,
    Tournaments
  }

  alias PairingsEngine.Tournaments.{Match, Player}

  defp teams(n, boards \\ 2) do
    for i <- 1..n, do: {"T#{i}", Enum.map(1..boards, &(2000 - i * 10 - &1))}
  end

  defp user_scope do
    user =
      Repo.insert!(%PairingsEngine.Accounts.User{
        email: "forfeit#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    PairingsEngine.Accounts.Scope.for_user(user)
  end

  defp team(t, name), do: t.id |> Tournaments.list_teams() |> Enum.find(&(&1.name == name))

  defp view(t, number) do
    teams = TeamRounds.numbered_teams(t.id)
    {field, _out} = TeamSwiss.split_field(t, teams, number)
    input = TeamSwiss.engine_input(t, teams, field, number)
    Map.new(input.teams, &{&1.tpn, &1})
  end

  defp results(t, round_number) do
    Tournaments.get_round(t.id, round_number).pairings
    |> Enum.sort_by(& &1.board)
    |> Enum.map(&{&1.board, &1.result})
  end

  # Round 1 of a four-team Swiss: T1-T3 and T4-T2, two boards each. T1 has
  # White on board 1 of its match, Black on board 2.
  defp swiss_round_one do
    {t, _} = team_swiss(teams(4), rounds: 3, tiebreaks: ~w(MP GP BH SB EMGSB))
    pair_next!(t)
    Repo.reload!(t)
  end

  describe "forfeiting a match by decision" do
    test "after games were played: forfeit wins for the team it was awarded to, and the decision is kept" do
      t = swiss_round_one()
      enter!(t, 1, "T1", "T3", ["1-0", "0-1"])
      enter!(t, 1, "T4", "T2", ["1/2-1/2", "1/2-1/2"])
      {match, _} = match_between(t, 1, "T1", "T3")
      t3 = team(t, "T3")

      assert {:ok, updated} = TeamMatches.forfeit_match(t, match, t3.id)
      assert updated.forfeited_to_team_id == t3.id
      assert updated.forfeit_previous_results == %{"1" => "1-0", "2" => "0-1"}

      # T3 is team B: Black on board 1, White on board 2.
      assert Enum.take(results(t, 1), 2) == [{1, "0-1FF"}, {2, "1-0FF"}]

      [scored | _] = TeamStandings.matches(t, through_round: 1)
      assert {scored.mp_a, scored.mp_b} == {0.0, 2.0}
      assert scored.forfeited_to == t3.id
      assert TeamStandings.match_played?(scored), "games were played before the decision"

      by_tpn = view(t, 2)
      tpn = fn name -> team(t, name).pairing_number end

      # [C2]: the team it was awarded to has won a match by forfeit.
      assert by_tpn[tpn.("T3")].won_by_forfeit?
      refute by_tpn[tpn.("T1")].won_by_forfeit?
      # [C1] and colours: the teams did play.
      assert by_tpn[tpn.("T3")].opponents == [tpn.("T1")]
      assert by_tpn[tpn.("T1")].colours == [:white]
    end

    test "over a match nobody sat down to, the match stays unplayed" do
      t = swiss_round_one()
      {match, _} = match_between(t, 1, "T1", "T3")
      t1 = team(t, "T1")

      {:ok, _} = TeamMatches.forfeit_match(t, match, t1.id)
      assert Enum.take(results(t, 1), 2) == [{1, "1-0FF"}, {2, "0-1FF"}]

      [scored | _] = TeamStandings.matches(t, through_round: 1)
      refute TeamStandings.match_played?(scored)

      by_tpn = view(t, 2)
      assert by_tpn[t1.pairing_number].won_by_forfeit?
      assert by_tpn[t1.pairing_number].opponents == []
    end

    test "a played match decided by forfeit is a played round for Article 16, scored as awarded" do
      t = swiss_round_one()
      enter!(t, 1, "T1", "T3", ["1-0", "1-0"])
      enter!(t, 1, "T4", "T2", ["1-0", "1-0"])
      {match, _} = match_between(t, 1, "T1", "T3")
      {:ok, _} = TeamMatches.forfeit_match(t, match, team(t, "T3").id)

      entry = t |> TeamStandings.standings() |> Enum.find(&(&1.team.name == "T1"))
      assert [%{kind: :played, value: value}] = entry.working["BH"]
      # T3's two match points, as awarded.
      assert value == 2.0
    end

    test "withdrawing the decision gives the boards back their results" do
      t = swiss_round_one()
      enter!(t, 1, "T1", "T3", ["1/2-1/2", "0-1"])
      before = results(t, 1)
      {match, _} = match_between(t, 1, "T1", "T3")

      {:ok, forfeited} = TeamMatches.forfeit_match(t, match, team(t, "T1").id)
      refute results(t, 1) == before

      assert {:ok, withdrawn} = TeamMatches.withdraw_forfeit(t, forfeited)
      assert results(t, 1) == before
      assert {withdrawn.forfeited_to_team_id, withdrawn.forfeit_previous_results} == {nil, nil}

      [scored | _] = TeamStandings.matches(t, through_round: 1)
      assert scored.forfeited_to == nil
      refute view(t, 2)[team(t, "T1").pairing_number].won_by_forfeit?
    end

    test "refuses a bye, a team from another match, a second decision, and withdrawing nothing" do
      {t, _} = team_swiss(teams(3), rounds: 3)
      pair_next!(t)
      t = Repo.reload!(t)
      matches = Tournaments.list_matches(Tournaments.get_round(t.id, 1).id)
      bye = Enum.find(matches, &is_nil(&1.team_b_id))
      played = Enum.find(matches, & &1.team_b_id)

      assert {:error, :bye_match} = TeamMatches.forfeit_match(t, bye, bye.team_a_id)
      assert {:error, :not_in_match} = TeamMatches.forfeit_match(t, played, bye.team_a_id)
      assert {:error, :not_forfeited} = TeamMatches.withdraw_forfeit(t, played)

      {:ok, decided} = TeamMatches.forfeit_match(t, played, played.team_a_id)

      assert {:error, :already_forfeited} =
               TeamMatches.forfeit_match(t, decided, decided.team_b_id)
    end

    test "a JSON backup carries the decision, so a restore can still withdraw it" do
      t = swiss_round_one()
      enter!(t, 1, "T1", "T3", ["1-0", "0-1"])
      {match, _} = match_between(t, 1, "T1", "T3")
      {:ok, _} = TeamMatches.forfeit_match(t, match, team(t, "T3").id)

      assert {:ok, [copy]} =
               TournamentImport.import(TournamentExport.export_tournament(t), user_scope())

      [copied] =
        Repo.all(
          from m in Match,
            join: r in assoc(m, :round),
            where: r.tournament_id == ^copy.id and not is_nil(m.forfeited_to_team_id)
        )

      assert team_name(copy, copied.forfeited_to_team_id) == "T3"
      assert copied.forfeit_previous_results == %{"1" => "1-0", "2" => "0-1"}

      {:ok, _} = TeamMatches.withdraw_forfeit(Repo.reload!(copy), copied)
      assert Enum.take(results(copy, 1), 2) == [{1, "1-0"}, {2, "0-1"}]
    end
  end

  defp team_name(t, id),
    do: t.id |> Tournaments.list_teams() |> Enum.find(&(&1.id == id)) |> Map.get(:name)

  describe "a board added by hand" do
    # A three-board team round robin, A against B, with one player of each
    # team unavailable when it was paired - so the match has two boards and
    # its third is free. `out` names the rostered position left out.
    defp short_match(out) do
      {t, _} =
        team_round_robin([{"A", [2100, 2000, 1900]}, {"B", [2050, 1950, 1850]}],
          boards: 3,
          rounds_count: 1
        )

      [a_out, b_out] =
        for name <- ["A #{out}", "B #{out}"] do
          p = Repo.one!(from p in Player, where: p.tournament_id == ^t.id and p.name == ^name)
          p |> Ecto.Changeset.change(absent: true) |> Repo.update!()
        end

      t = pair_all!(t)

      for p <- [a_out, b_out],
          do: p |> Repo.reload!() |> Ecto.Changeset.change(absent: false) |> Repo.update!()

      round = Tournaments.get_round(t.id, 1)
      {t, round, Repo.reload!(a_out), Repo.reload!(b_out)}
    end

    test "joins the match when it fits: its teams, a free board, the colours and the board order" do
      {t, round, a3, b3} = short_match(3)
      assert length(round.pairings) == 2

      # A is team A: White on board 3.
      assert {:ok, match} = TeamMatches.slot_at(t, round, a3.id, b3.id, 3)
      assert {:error, :colours} = TeamMatches.slot_at(t, round, b3.id, a3.id, 3)
      assert {:error, :board_taken} = TeamMatches.slot_at(t, round, a3.id, b3.id, 1)
      assert {:error, :no_match} = TeamMatches.slot_at(t, round, a3.id, b3.id, 4)

      assert {:ok, %{board: 3, white_id: white, match: ^match}} =
               TeamMatches.fitting_slot(t, round, b3.id, a3.id)

      assert white == a3.id

      {:ok, created} = Tournaments.pair_from_pool(round, a3.id, b3.id, 3)
      assert created.match_id == match.id

      [scored] = TeamStandings.matches(t)
      assert length(scored.boards) == 3
      assert TeamMatches.unattached_boards(t, Tournaments.get_round(t.id, 1)) == []
    end

    test "a board whose board orders do not line up stays outside, counting for no team" do
      # A 2 and B 2 were out: A 3 and B 3 sit at board 2, so 2 cannot come after them.
      {t, round, a2, b2} = short_match(2)

      assert {:error, :board_order} = TeamMatches.slot_at(t, round, a2.id, b2.id, 3)

      {:ok, created} = Tournaments.pair_from_pool(round, a2.id, b2.id, 3)
      assert created.match_id == nil

      {:ok, _} = Tournaments.update_pairing_result(created, "1-0")
      [scored] = TeamStandings.matches(t)
      assert length(scored.boards) == 2
      assert scored.gp_a + scored.gp_b == 0.0

      round = Tournaments.get_round(t.id, 1)
      assert [%{id: id}] = TeamMatches.unattached_boards(t, round)
      assert id == created.id
    end

    test "players of the same team, or of no team, never join a match" do
      {t, round, a3, _b3} = short_match(3)

      a1 = Repo.one!(from p in Player, where: p.tournament_id == ^t.id and p.name == "A 1")
      assert {:error, :no_team} = TeamMatches.slot_at(t, round, a3.id, a1.id, 3)

      {:ok, loner} =
        Tournaments.create_player(t.id, %{"name" => "Loner", "fide_rating" => "1500"})

      assert {:error, :no_team} = TeamMatches.slot_at(t, round, a3.id, loner.id, 3)
    end

    test "attach_board/3 moves a board outside every match into the one it fits" do
      {t, round, a3, b3} = short_match(3)
      {:ok, outside} = Tournaments.pair_from_pool(round, b3.id, a3.id, 7)
      assert outside.match_id == nil

      round = Tournaments.get_round(t.id, 1)
      assert {:ok, attached} = TeamMatches.attach_board(t, round, outside)

      assert {attached.board, attached.white_player_id, attached.black_player_id} ==
               {3, a3.id, b3.id}

      assert attached.match_id

      assert TeamMatches.unattached_boards(t, Tournaments.get_round(t.id, 1)) == []
    end

    test "attach_board/3 will not swap the colours of a board that has a result" do
      {t, round, a3, b3} = short_match(3)
      {:ok, outside} = Tournaments.pair_from_pool(round, b3.id, a3.id, 7)
      {:ok, outside} = Tournaments.update_pairing_result(outside, "1-0")

      assert {:error, :colours} =
               TeamMatches.attach_board(t, Tournaments.get_round(t.id, 1), outside)
    end

    test "an individual tournament's pool board is untouched" do
      t =
        Repo.insert!(%PairingsEngine.Tournaments.Tournament{
          name: "Open",
          type: "swiss",
          rounds_count: 1
        })

      players =
        for n <- ~w(P1 P2 P3 P4) do
          {:ok, p} = Tournaments.create_player(t.id, %{"name" => n, "fide_rating" => "1500"})
          p
        end

      round = Repo.insert!(%PairingsEngine.Tournaments.Round{tournament_id: t.id, number: 1})
      [p1, p2 | _] = players
      {:ok, created} = Tournaments.pair_from_pool(round, p1.id, p2.id, 1)
      assert created.match_id == nil
      assert TeamMatches.unattached_boards(t, Tournaments.get_round(t.id, 1)) == []
    end
  end
end
