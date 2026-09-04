defmodule PairingsEngine.TrfExportRoundDatesTest do
  @moduledoc """
  A TRF that names rounds must carry a date for each of them.

  FIDE requires it, and a file that reaches them without it comes back after
  the event - when fixing it means re-exporting and re-submitting rather than
  filling in a field. Refusing at the download is the same fact delivered
  while it is still five minutes of work.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Repo, Tournaments, TrfExport}
  alias PairingsEngine.Tournaments.Player
  alias PairingsEngine.Pairing, as: Engine

  defp tournament_with(players, rounds_to_pair) do
    scope = user_scope_fixture()
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Dates", "type" => "swiss"})

    for n <- 1..players do
      Repo.insert!(%Player{
        tournament_id: t.id,
        name: "Player #{n}",
        pairing_number: n,
        fide_rating: 2000,
        federation: "BEL"
      })
    end

    # A round cannot be paired while the one before it is unscored, so score
    # as we go - this fixture is about dates, not about pairing.
    for n <- 1..rounds_to_pair//1 do
      {:ok, _} = Engine.pair_next_round(t)
      round = Tournaments.get_round(t.id, n)

      for pairing <- round.pairings, pairing.black_player_id != nil do
        {:ok, _} = Tournaments.update_pairing_result(pairing, "1-0")
      end
    end

    Repo.get!(Tournaments.Tournament, t.id)
  end

  test "a roster taken before any pairing still exports" do
    # The case that made a blanket refusal wrong: 226 players, no rounds, and
    # no round dates possible. It is the file an arbiter checks a registration
    # list against.
    t = tournament_with(4, 0)

    assert {:ok, trf} = TrfExport.export(t)
    assert trf =~ "142 0"
  end

  test "a paired round with no date is refused, and says which round" do
    t = tournament_with(4, 1)

    assert {:error, %Ainalrami.Trf.ValidationError{message: message}} = TrfExport.export(t)
    assert message =~ "round 1"
    assert message =~ "Settings, Dates"
  end

  test "and exports once the date is there" do
    t = tournament_with(4, 1)
    {:ok, t} = Tournaments.update_tournament(t, %{round_dates: ["2026-08-15"]})

    assert {:ok, trf} = TrfExport.export(t)
    assert trf =~ "132"
  end

  test "every dateless round is named, not just the first" do
    t = tournament_with(4, 2)
    {:ok, t} = Tournaments.update_tournament(t, %{round_dates: ["2026-08-15"]})

    assert {:error, %Ainalrami.Trf.ValidationError{message: message}} = TrfExport.export(t)
    assert message =~ "round 2"
    refute message =~ "rounds 1", "round 1 has a date and must not be blamed"
  end

  test "a partial export only needs dates for the rounds it contains" do
    # `?rounds=1` of a two-round event is a file about round 1. Round 2's
    # missing date is none of its business.
    t = tournament_with(4, 2)
    {:ok, t} = Tournaments.update_tournament(t, %{round_dates: ["2026-08-15"]})

    assert {:ok, _trf} = TrfExport.export(t, "1")
  end
end
