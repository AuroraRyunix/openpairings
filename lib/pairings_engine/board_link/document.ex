defmodule PairingsEngine.BoardLink.Document do
  @moduledoc """
  What a hall box is told about one tournament: who sits where, in which
  round, at what rate of play, and where to send the moves. The fields are
  specified in `docs/board-link-api.md`; this builds them.

  ## An allowlist

  Like `PairingsEngine.Snapshot`, every key is written out by hand. A box in
  a room full of people learns what a spectator could read off the pairing
  sheet, plus the ids it needs to report back: a name, a title, a rating, a
  federation, a FIDE id. No address, no birth date, no phone number, no
  club, no fee - and nothing that is added to a player next year, unless
  somebody adds it here on purpose.

  ## The version

  `version/1` changes when the document would. It does not build the
  document to find out: it hashes the handful of tournament settings the
  document reads, `tournaments.data_version` - which database triggers move
  with every write to the tournament's players, rounds, pairings and byes
  (`PairingsEngine.StandingsCache`) - the publishing target, and, for a team
  event, the teams and matches. So a box asking "anything new?" every few
  seconds costs a row read, not a tournament.

  Over-eager is allowed (a result entered moves the version, and the
  document then carries that result). Missing a change is not.
  """

  import Ecto.Query

  alias PairingsEngine.{BoardLink, PairingDisplay, PublicDisplay, Repo, Results, Tournaments}
  alias PairingsEngine.BoardLink.TimeControl
  alias PairingsEngine.Tournaments.{Match, Player, Round, Team, Tournament}

  @settings ~w(name venue city federation start_date end_date time_control rate_of_play
               standard rounds_count round_dates chess960 type team_boards public_live_boards
               public_display status)a

  @doc "A short opaque string that differs whenever `document/1` would."
  @spec version(Tournament.t()) :: String.t()
  def version(%Tournament{} = t) do
    data_version =
      Repo.one(from x in "tournaments", where: x.id == ^t.id, select: x.data_version)

    {data_version, Map.take(t, @settings), BoardLink.openresults_target(t), team_fingerprint(t)}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 20)
  end

  defp team_fingerprint(%Tournament{} = t) do
    if Tournament.team?(t) do
      teams = Repo.all(from x in Team, where: x.tournament_id == ^t.id, select: {x.id, x.name})

      matches =
        Repo.all(
          from m in Match,
            join: r in Round,
            on: m.round_id == r.id,
            where: r.tournament_id == ^t.id,
            select: {m.id, r.number, m.board, m.team_a_id, m.team_b_id}
        )

      {Enum.sort(teams), Enum.sort(matches)}
    end
  end

  @doc "The document for `tournament`, as a map ready for JSON."
  @spec document(Tournament.t()) :: map()
  def document(%Tournament{} = t) do
    rounds =
      Repo.all(
        from r in Round.without_explanation(),
          where: r.tournament_id == ^t.id,
          order_by: r.number,
          preload: [pairings: [:white_player, :black_player]]
      )

    teams = team_names(t)
    matches = matches_by_id(t, rounds)
    current = current_round(rounds)

    %{
      "version" => version(t),
      "tournament" => %{
        "id" => t.id,
        "name" => t.name,
        "site" => blank_to_nil(t.venue) || blank_to_nil(t.city),
        "city" => blank_to_nil(t.city),
        "federation" => blank_to_nil(t.federation),
        "start_date" => blank_to_nil(t.start_date),
        "end_date" => blank_to_nil(t.end_date),
        "rounds" => t.rounds_count,
        "state" => t.status,
        "team_event" => Tournament.team?(t),
        "boards_per_match" => if(Tournament.team?(t), do: t.team_boards),
        "chess960" => t.chess960 == true,
        "time_control" => time_control(t),
        "live_boards" => t.public_live_boards == true,
        # The arbiter's ticks for the results site. The box is given every
        # field and told which ones the public page shows, so that what it
        # forwards to a third party can keep to the same line.
        "display" =>
          Map.new(~w(rating title federation), &{&1, PublicDisplay.show?(t.public_display, &1)})
      },
      "current_round" => current,
      "players" => players(t, rounds, teams),
      "rounds" => Enum.map(rounds, &round(&1, t, current, matches)),
      "openresults" => BoardLink.openresults_target(t)
    }
  end

  defp time_control(%Tournament{} = t) do
    parsed = TimeControl.parse(t.rate_of_play)

    %{
      "text" => blank_to_nil(t.rate_of_play) || blank_to_nil(t.time_control),
      "kind" => blank_to_nil(t.standard),
      "pgn" => TimeControl.pgn(t.rate_of_play),
      "periods" =>
        parsed && Enum.map(parsed.periods, &%{"moves" => &1.moves, "seconds" => &1.seconds}),
      "increment_seconds" => parsed && parsed.increment_seconds,
      "increment_from_move" => parsed && parsed.increment_from_move
    }
  end

  # The round to have on the boards: the first paired round still waiting
  # for a result, or the last one when none is. There is no "start the
  # round" button in OpenPairings - a round that is paired is on, which is
  # why a Swiss needs nothing more than this. A round robin pairs every
  # round at once, and there the first unfinished one is the one being
  # played.
  defp current_round([]), do: nil

  defp current_round(rounds) do
    case Enum.find(rounds, &open?/1) do
      %Round{number: number} -> number
      nil -> List.last(rounds).number
    end
  end

  defp open?(%Round{pairings: pairings}),
    do: Enum.any?(pairings, &(kind(&1) == "game" and &1.result == ""))

  defp round(%Round{} = round, %Tournament{} = t, current, matches) do
    %{
      "number" => round.number,
      "date" =>
        blank_to_nil(round.date) || blank_to_nil(Enum.at(t.round_dates || [], round.number - 1)),
      "state" =>
        cond do
          round.number == current -> "current"
          round.number < current -> "finished"
          true -> "upcoming"
        end,
      # The round's drawn start position, 0 to 959, in a Chess960 event.
      "chess960_position" => round.chess960_position,
      "boards" =>
        round.pairings
        |> Enum.reject(&(&1.hidden or is_nil(&1.game_uid) or kind(&1) == "empty"))
        |> Enum.sort_by(& &1.board)
        |> Enum.map(&board(&1, matches))
    }
  end

  defp board(pairing, matches) do
    %{
      "game" => pairing.game_uid,
      # Two numbers, as in the snapshot: `board` is the engine's own, unique
      # in the round, and what the results site keys a live game on; `label`
      # is what is printed on the pairing sheet and stuck on the table.
      "board" => pairing.board,
      "label" => pairing |> PairingDisplay.board_label() |> to_string(),
      "kind" => kind(pairing),
      "white" => pairing.white_player_id,
      "black" => pairing.black_player_id,
      # The arbiter's result, as entered. Null until there is one.
      "result" => blank_to_nil(pairing.result)
    }
    |> put_match(pairing, matches)
  end

  defp put_match(row, %{match_id: nil}, _matches), do: row

  defp put_match(row, pairing, matches) do
    case Map.get(matches, pairing.match_id) do
      nil ->
        row

      match ->
        Map.put(row, "match", %{
          "number" => match.number,
          "board" => Map.get(match.positions, pairing.id),
          "team_a" => match.team_a,
          "team_b" => match.team_b
        })
    end
  end

  # "game" is the only kind a board should be set up for.
  defp kind(pairing) do
    cond do
      is_nil(pairing.white_player_id) and is_nil(pairing.black_player_id) -> "empty"
      pairing.result == "bye" -> "bye"
      is_nil(pairing.white_player_id) or is_nil(pairing.black_player_id) -> "bye"
      Results.forfeit?(pairing.result) -> "forfeit"
      true -> "game"
    end
  end

  defp players(%Tournament{} = t, rounds, teams) do
    rounds
    |> Enum.flat_map(& &1.pairings)
    |> Enum.reject(& &1.hidden)
    |> Enum.flat_map(&[&1.white_player, &1.black_player])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn %Player{} = p ->
      %{
        "id" => p.id,
        "no" => p.pairing_number,
        "name" => p.name,
        "title" => blank_to_nil(p.title),
        "rating" => zero_to_nil(Player.rating(p, t)),
        "federation" => blank_to_nil(p.federation),
        "fide_id" => p.fide_id,
        "team" => Map.get(teams, p.team_id)
      }
    end)
  end

  defp team_names(%Tournament{} = t) do
    if Tournament.team?(t),
      do: Map.new(Tournaments.list_teams(t.id), &{&1.id, &1.name}),
      else: %{}
  end

  # A match's place in the round and each of its boards' place in the match
  # (1 to `team_boards`), read off the boards themselves - the same rule the
  # snapshot's `board_positions` follows.
  defp matches_by_id(%Tournament{} = t, rounds) do
    if Tournament.team?(t) do
      for round <- rounds, match <- Tournaments.list_matches(round.id), into: %{} do
        positions =
          round.pairings
          |> Enum.filter(&(&1.match_id == match.id))
          |> Enum.sort_by(& &1.board)
          |> Enum.with_index(1)
          |> Map.new(fn {pairing, k} -> {pairing.id, k} end)

        {match.id,
         %{
           number: match.board,
           positions: positions,
           team_a: match.team_a && match.team_a.name,
           team_b: match.team_b && match.team_b.name
         }}
      end
    else
      %{}
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp zero_to_nil(0), do: nil
  defp zero_to_nil(value), do: value
end
