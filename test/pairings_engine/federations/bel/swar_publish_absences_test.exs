defmodule PairingsEngine.Federations.BEL.SwarPublishAbsencesTest do
  @moduledoc """
  A player who told the arbiter they would be away still appears on the page.

  Absences are not pairings - they live in the `byes` table - so nothing about
  them reached the results table and those people were simply missing. SWAR
  writes them with a second function beside its bye writer, the same row shape
  with the absence's own point value and "Afwezig" rather than "Bye".
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}
  alias PairingsEngine.Federations.BEL.SwarPublish

  defp build(type) do
    {:ok, t} =
      Tournaments.create_tournament(user_scope_fixture(), %{
        "name" => "Absences",
        "type" => "swiss",
        "round_dates" => ["2026-08-01"],
        "organizer_club_number" => "351"
      })

    [a, b, away] =
      for {name, n} <- [{"Alpha, A", 1}, {"Beta, B", 2}, {"Away, Ann", 3}] do
        Repo.insert!(%Player{
          tournament_id: t.id,
          name: name,
          pairing_number: n,
          fide_rating: 1800
        })
      end

    round = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "playing"})

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1-0"
    })

    Repo.insert_all("byes", [
      %{tournament_id: t.id, player_id: away.id, round: 1, type: type}
    ])

    {Repo.get!(Tournaments.Tournament, t.id), away}
  end

  test "an absent player appears, named, with the absence wording" do
    {t, away} = build("absent")
    html = SwarPublish.export(t)

    assert html =~ away.name
    assert html =~ "Afwezig"
  end

  test "a requested half-point bye shows the half it is worth" do
    {t, _away} = build("requested-half")
    html = SwarPublish.export(t)

    # Whatever the tournament scores a half-point request, the page shows the
    # same figure the standings do - it is read from Standings, not decided
    # again here.
    assert html =~ "Afwezig"
    assert html =~ "½" or html =~ "0.5"
  end

  test "a requested zero shows a zero, not a blank" do
    {t, _away} = build("requested-zero")
    html = SwarPublish.export(t)

    assert html =~ "Afwezig"
  end

  test "the played board is still there alongside" do
    {t, _away} = build("absent")
    html = SwarPublish.export(t)

    assert html =~ "Alpha, A"
    assert html =~ "Beta, B"
    assert html =~ "1-0"
  end

  test "a round with no absences gains no absence rows" do
    {:ok, t} =
      Tournaments.create_tournament(user_scope_fixture(), %{
        "name" => "None",
        "type" => "swiss",
        "round_dates" => ["2026-08-01"],
        "organizer_club_number" => "351"
      })

    html = SwarPublish.export(Repo.get!(Tournaments.Tournament, t.id))
    refute html =~ "Afwezig"
  end
end
