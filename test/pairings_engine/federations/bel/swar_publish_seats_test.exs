defmodule PairingsEngine.Federations.BEL.SwarPublishSeatsTest do
  @moduledoc """
  A board with an empty seat must not take the page down.

  An arbiter can vacate a seat rather than delete the pairing, so a round
  legitimately carries a pairing with one player, or none. Reading `.id` off
  the nil that is there returned a 500 for the whole tournament - found on the
  live server, on a real tournament, the first time anybody asked for its SWAR
  page.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}
  alias PairingsEngine.Federations.BEL.SwarPublish

  defp tournament_with_pairings(pairs) do
    {:ok, t} =
      Tournaments.create_tournament(user_scope_fixture(), %{
        "name" => "Seats",
        "type" => "swiss",
        "round_dates" => ["2026-08-01"],
        "organizer_club_number" => "351"
      })

    players =
      for n <- 1..4 do
        Repo.insert!(%Player{
          tournament_id: t.id,
          name: "Player #{n}",
          pairing_number: n,
          fide_rating: 1900
        })
      end

    round = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "playing"})

    for {{w, b}, board} <- Enum.with_index(pairs, 1) do
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: board,
        white_player_id: w && Enum.at(players, w - 1).id,
        black_player_id: b && Enum.at(players, b - 1).id,
        result: ""
      })
    end

    Repo.get!(Tournaments.Tournament, t.id)
  end

  test "an ordinary board still renders" do
    html = SwarPublish.export(tournament_with_pairings([{1, 2}]))
    assert html =~ "Player 1"
    assert html =~ "Player 2"
  end

  test "a bye renders the seated player, not a crash" do
    html = SwarPublish.export(tournament_with_pairings([{1, nil}]))
    assert html =~ "Player 1"
  end

  test "a board with only black seated renders too" do
    # The mirror of a bye. It reached the general clause and died on
    # `white.id` - which is exactly how the live 500 happened.
    html = SwarPublish.export(tournament_with_pairings([{nil, 2}]))
    assert html =~ "Player 2"
  end

  test "a fully vacated board renders nothing at all, and no empty row" do
    html = SwarPublish.export(tournament_with_pairings([{1, 2}, {nil, nil}]))

    assert html =~ "Player 1"
    refute html =~ "nil", "a skipped row must not leak the atom into the document"
  end

  test "a round mixing every shape renders end to end" do
    html = SwarPublish.export(tournament_with_pairings([{1, 2}, {3, nil}, {nil, 4}, {nil, nil}]))

    for n <- 1..4, do: assert(html =~ "Player #{n}")
  end
end
