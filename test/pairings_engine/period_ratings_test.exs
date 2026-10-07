defmodule PairingsEngine.PeriodRatingsTest do
  @moduledoc """
  A tournament lasting more than 30 days (VCL4THP Q210-Q216): the flag, a
  player's later ratings linked to the rounds they apply from, the rating
  the rating-based tie-breaks use (the first by default, or the one the
  arbiter chose), the expected scores per game, and the TRF's rating
  column for a file of one rating period.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Pairing, PeriodRatings, Repo, Standings, TrfExport, Tournaments}
  alias PairingsEngine.Standings.AinalramiBridge
  alias PairingsEngine.Tournaments.{Player, Tournament}

  describe "parse/1 and format/1" do
    test "round:rating pairs, sorted, one per round" do
      assert {:ok, list} = PeriodRatings.parse("9:1872, 5:1850")

      assert list == [
               %{"from_round" => 5, "fide_rating" => 1850},
               %{"from_round" => 9, "fide_rating" => 1872}
             ]

      assert PeriodRatings.format(list) == "5:1850, 9:1872"
      assert PeriodRatings.parse("") == {:ok, []}
    end

    test "refuses round 1, a rating out of range and anything else" do
      assert PeriodRatings.parse("1:1850") == :error
      assert PeriodRatings.parse("5:5000") == :error
      assert PeriodRatings.parse("five:1850") == :error
    end
  end

  describe "at_round/3" do
    test "the rating valid in a round, the first before any later one" do
      p = %Player{
        fide_rating: 1800,
        national_rating: 1750,
        period_ratings: [
          %{"from_round" => 4, "fide_rating" => 1830},
          %{"from_round" => 7, "fide_rating" => 1860, "national_rating" => 1800}
        ]
      }

      long = %Tournament{long_event: true}
      assert PeriodRatings.at_round(p, 3, long).fide_rating == 1800
      assert PeriodRatings.at_round(p, 4, long).fide_rating == 1830
      assert PeriodRatings.at_round(p, 6, long).national_rating == 1750
      assert PeriodRatings.at_round(p, 9, long).fide_rating == 1860
      assert PeriodRatings.at_round(p, 9, long).national_rating == 1800

      # Not a long event: untouched.
      assert PeriodRatings.at_round(p, 9, %Tournament{}).fide_rating == 1800
    end

    test "tiebreak_round/1 is the first rating unless the arbiter chose a round" do
      assert PeriodRatings.tiebreak_round(%Tournament{}) == 1
      assert PeriodRatings.tiebreak_round(%Tournament{long_event: true}) == 1

      assert PeriodRatings.tiebreak_round(%Tournament{long_event: true, tiebreak_rating_round: 5}) ==
               5

      assert PeriodRatings.tiebreak_round(%Tournament{tiebreak_rating_round: 5}) == 1
    end
  end

  test "spans_over_30_days?/1 reads the round dates" do
    assert PeriodRatings.spans_over_30_days?(%Tournament{
             round_dates: ~w(2026-09-01 2026-10-15)
           })

    refute PeriodRatings.spans_over_30_days?(%Tournament{
             round_dates: ~w(2026-09-01 2026-09-08)
           })

    assert PeriodRatings.span_days(%Tournament{start_date: "2026/01/01", end_date: "2026/03/01"}) ==
             59
  end

  describe "in a tournament" do
    setup do
      t =
        Repo.insert!(%Tournament{
          name: "Winter league",
          type: "swiss",
          rounds_count: 4,
          tiebreaks: ~w(ARO BH),
          long_event: true,
          round_dates: ~w(2026-09-01 2026-09-29 2026-10-27 2026-11-24)
        })

      players =
        for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}],
            into: %{} do
          {:ok, p} =
            Tournaments.create_player(t.id, %{
              tournament_id: t.id,
              name: name,
              fide_rating: rating
            })

          {name, p}
        end

      {:ok, carol} =
        Tournaments.update_player(players["Carol"], %{"period_ratings_text" => "3:1850"})

      %{t: t, players: Map.put(players, "Carol", carol)}
    end

    test "the players form spelling is stored as the list, and emptied", %{players: ps} do
      assert ps["Carol"].period_ratings == [%{"from_round" => 3, "fide_rating" => 1850}]

      {:ok, cleared} = Tournaments.update_player(ps["Carol"], %{"period_ratings_text" => ""})
      assert cleared.period_ratings == []

      assert {:error, changeset} =
               Tournaments.update_player(ps["Carol"], %{"period_ratings_text" => "nonsense"})

      assert changeset.errors[:period_ratings_text]
    end

    test "the rating-based tie-breaks use the first rating, or the round chosen", %{
      t: t,
      players: ps
    } do
      entries = Standings.standings(t)
      event = AinalramiBridge.event(entries, t, 0)
      assert Map.fetch!(event.participants, ps["Carol"].id).rating == 1800

      chosen = %{t | tiebreak_rating_round: 3}
      event = AinalramiBridge.event(entries, chosen, 0)
      assert Map.fetch!(event.participants, ps["Carol"].id).rating == 1850
    end

    test "a TRF of a later period carries that period's rating", %{t: t, players: ps} do
      for _ <- 1..3 do
        {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))

        for p <- Tournaments.get_round(t.id, round.number).pairings, p.black_player_id do
          {:ok, _} = Tournaments.update_pairing_result(p, "1/2-1/2")
        end
      end

      carol_rating = fn text ->
        text
        |> String.split("\r\n")
        |> Enum.find(&(String.starts_with?(&1, "001") and &1 =~ "Carol"))
        |> String.slice(48, 4)
      end

      {:ok, first} = TrfExport.export(Repo.reload!(t), "1-2")
      assert carol_rating.(first) == "1800"

      {:ok, later} = TrfExport.export(Repo.reload!(t), "3")
      assert carol_rating.(later) == "1850"

      # Not a long event any more: one rating, whatever the rounds.
      {:ok, plain} = Tournaments.update_tournament(Repo.reload!(t), %{"long_event" => "false"})
      {:ok, later} = TrfExport.export(plain, "3")
      assert carol_rating.(later) == "1800"
      _ = ps
    end

    test "expected scores count each game with the ratings of its round", %{t: t, players: ps} do
      carol = Repo.reload!(ps["Carol"])
      alice = Repo.reload!(ps["Alice"])
      by_id = %{alice.id => alice}

      games = [
        %{round: 1, opponent_id: alice.id, points: 0.0},
        %{round: 3, opponent_id: alice.id, points: 1.0}
      ]

      {we, w} = PeriodRatings.expected_score(carol, games, by_id, t)
      # Round 1: 1800 v 2000 (-200) = 0.24; round 3: 1850 v 2000 (-150) = 0.30.
      assert we == 0.54
      assert w == 1.0

      {we, _} = PeriodRatings.expected_score(carol, games, by_id, %{t | long_event: false})
      assert we == 0.48
    end
  end
end
