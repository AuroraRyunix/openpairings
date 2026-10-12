defmodule PairingsEngine.BoardLinkFixtures do
  @moduledoc """
  A small paired tournament for the board-link tests: four players, one
  round, two boards - built with plain inserts, because what those tests are
  about is the link and not the pairing engine.
  """

  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  @doc """
  `%{tournament:, players: [a, b, c, d], round:, boards: [board1, board2]}` -
  board 1 is `a` (White) against `b`, board 2 is `c` against `d`. The boards
  are read back after the insert, so each carries the `game_uid` the
  database gave it.
  """
  def paired_tournament(scope, attrs \\ %{}) do
    tournament =
      Repo.insert!(
        struct!(
          %Tournament{
            name: "Board Link Open",
            type: "swiss",
            rounds_count: 3,
            round_dates: ["2026-10-12", "2026-10-13", "2026-10-14"],
            tiebreaks: ["BH"],
            city: "Somewhere",
            start_date: "2026-10-12",
            rate_of_play: "90min/40moves+30min/end+30sec/move from move 1",
            user_id: scope.user.id
          },
          attrs
        )
      )

    players =
      for n <- 1..4 do
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: "Player #{n}",
          pairing_number: n,
          fide_rating: 2000 - n * 10,
          federation: "BEL",
          birth_year: 1970 + n,
          club: "Secret Club #{n}"
        })
      end

    [a, b, c, d] = players
    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

    boards =
      for {board, white, black} <- [{1, a, b}, {2, c, d}] do
        pairing =
          Repo.insert!(%Pairing{
            round_id: round.id,
            board: board,
            white_player_id: white.id,
            black_player_id: black.id
          })

        Repo.get!(Pairing, pairing.id)
      end

    %{tournament: tournament, players: players, round: round, boards: boards}
  end

  @doc "A report for `pairing` as a box would post it."
  def report_for(%Pairing{} = pairing, attrs \\ %{}) do
    Map.merge(
      %{
        "game" => pairing.game_uid,
        "white" => pairing.white_player_id,
        "black" => pairing.black_player_id,
        "seq" => 1,
        "moves" => ["e4", "e5", "Nf3"],
        "status" => "live"
      },
      attrs
    )
  end
end
