defmodule PairingsEngine.Norms.TitleNormsEventTypeTest do
  @moduledoc """
  The event-type rules of the FIDE Title Regulations (B.01): the game-count
  concessions of 1.4.1 (b) and the federation-mix exemptions of 1.4.3
  (a)-(c), as `Tournament.norm_event_type` switches them on.

  Every fixture gives the candidate nothing but wins against 2600-rated GMs,
  so every requirement except the one under test passes with room to spare:
  Ra 2600, 100% -> dp 800, every opponent titled and a GM. What is left is
  exactly the game count or the federation mix.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.Norms.TitleNorms
  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  # `games` wins for the candidate; opponent federations cycle through
  # `opp_feds`.
  defp fixture(opts) do
    tournament =
      Repo.insert!(%Tournament{
        name: "Event type norm test",
        type: Keyword.get(opts, :type, "team-swiss"),
        rounds_count: Keyword.get(opts, :rounds, 9),
        federation: Keyword.get(opts, :federation, "BEL"),
        norm_event_type: Keyword.get(opts, :event_type, "ordinary"),
        points_win: 1.0,
        points_draw: 0.5,
        points_loss: 0.0
      })

    candidate =
      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Candidate",
        federation: Keyword.get(opts, :candidate_fed, "BEL"),
        fide_rating: 2450,
        pairing_number: 1
      })

    feds = Keyword.get(opts, :opp_feds, ~w(FRA NED GER))
    games = Keyword.fetch!(opts, :games)

    for i <- 1..games do
      opp =
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: "Opponent #{i}",
          title: "GM",
          federation: Enum.at(feds, rem(i - 1, length(feds))),
          fide_rating: 2600,
          pairing_number: i + 1
        })

      round =
        Repo.insert!(%Round{tournament_id: tournament.id, number: i, status: "finished"})

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: candidate.id,
        black_player_id: opp.id,
        result: "1-0"
      })
    end

    {tournament, candidate}
  end

  defp gm_verdict(opts) do
    {tournament, candidate} = fixture(opts)

    tournament
    |> TitleNorms.evaluate()
    |> Map.fetch!(candidate.id)
    |> Map.fetch!(:verdicts)
    |> Enum.find(&(&1.title == "GM"))
  end

  defp check(verdict, name), do: Enum.find(verdict.checks, &(&1.name == name))

  describe "1.4.1 (a): an ordinary event needs 9 games" do
    test "8 games fall short, 9 are enough - also on a team tournament" do
      refute gm_verdict(games: 8).achieved?
      refute check(gm_verdict(games: 8), :games).ok?
      assert gm_verdict(games: 9).achieved?
    end
  end

  describe "1.4.1 (b): World/Continental Team or Club Championship of 7-9 rounds" do
    test "a 9-round team championship: 7 games are enough, 6 are not" do
      assert gm_verdict(games: 7, event_type: "team_championship", rounds: 9).achieved?

      v = gm_verdict(games: 6, event_type: "team_championship", rounds: 9)
      refute v.achieved?
      refute check(v, :games).ok?
      assert check(v, :games).detail =~ "need 7"
    end

    test "an 8-round club championship: 7 games are enough" do
      assert gm_verdict(games: 7, event_type: "club_championship", rounds: 8).achieved?
    end

    test "a 7-round team championship: 7 games are enough" do
      assert gm_verdict(games: 7, event_type: "team_championship", rounds: 7).achieved?
    end

    test "outside 7-9 rounds the concession does not apply: 10 rounds need 9 games" do
      v = gm_verdict(games: 8, event_type: "team_championship", rounds: 10)
      refute check(v, :games).ok?
      assert check(v, :games).detail =~ "need 9"

      assert gm_verdict(games: 9, event_type: "team_championship", rounds: 10).achieved?
    end

    test "on an individual tournament the team kinds are not applied" do
      v = gm_verdict(games: 7, event_type: "team_championship", rounds: 9, type: "swiss")
      refute check(v, :games).ok?
      assert check(v, :games).detail =~ "need 9"
    end
  end

  describe "1.4.1 (b): World Cup / Women's World Cup" do
    test "8 games are enough, 7 are not" do
      assert gm_verdict(games: 8, event_type: "world_cup", type: "swiss").achieved?
      refute gm_verdict(games: 7, event_type: "world_cup", type: "swiss").achieved?
    end

    test "not applied on a team tournament" do
      refute gm_verdict(games: 8, event_type: "world_cup").achieved?
    end
  end

  describe "1.4.3 (b): national team championship" do
    test "exempts a player of the registering federation from the federation mix" do
      opts = [games: 9, opp_feds: ~w(BEL), candidate_fed: "BEL"]

      ordinary = gm_verdict(opts)
      refute check(ordinary, :foreign_federations).ok?
      refute check(ordinary, :own_federation_share).ok?
      refute ordinary.achieved?

      exempt = gm_verdict([event_type: "national_team_championship"] ++ opts)
      assert exempt.achieved?
      assert check(exempt, :foreign_federations).detail =~ "1.4.3 (b)"
      assert check(exempt, :own_federation_share).ok?
      assert check(exempt, :single_federation_share).ok?
    end

    test "does not exempt a player of another federation" do
      v =
        gm_verdict(
          games: 9,
          opp_feds: ~w(BEL),
          candidate_fed: "NED",
          event_type: "national_team_championship"
        )

      refute check(v, :foreign_federations).ok?
      refute v.achieved?
    end

    test "with no registering federation set, nobody is exempt" do
      v =
        gm_verdict(
          games: 9,
          opp_feds: ~w(BEL),
          federation: "",
          event_type: "national_team_championship"
        )

      refute v.achieved?
    end
  end

  describe "1.4.3 (a) and (c) on individual tournaments" do
    test "final stage of a national championship exempts the registering federation's players" do
      opts = [games: 9, opp_feds: ~w(BEL), type: "swiss"]

      refute gm_verdict(opts).achieved?
      assert gm_verdict([event_type: "national_championship"] ++ opts).achieved?

      refute gm_verdict([event_type: "national_championship", candidate_fed: "NED"] ++ opts).achieved?
    end

    test "a zonal exempts everyone; on a team tournament it is not applied" do
      opts = [games: 9, opp_feds: ~w(BEL), candidate_fed: "NED"]

      assert gm_verdict([event_type: "zonal", type: "swiss"] ++ opts).achieved?
      refute gm_verdict([event_type: "zonal"] ++ opts).achieved?
    end
  end

  test "an unknown event type is refused by the changeset" do
    changeset =
      Tournament.changeset(%Tournament{}, %{
        name: "x",
        type: "swiss",
        rounds_count: 9,
        norm_event_type: "olympiad"
      })

    refute changeset.valid?
    assert changeset.errors[:norm_event_type]
  end
end
