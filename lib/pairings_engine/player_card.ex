defmodule PairingsEngine.PlayerCard do
  @moduledoc """
  Pure helpers for the SWAR-style "Players Card" (right-click on a player row):
  one row per game played, with the opponent's rating/current total, the own
  result label, colour and "float" indicator. Kept separate from
  `PairingsEngineWeb.PlayersLive` so the arithmetic can be unit tested without
  a LiveView/DB fixture.

  A standings "entry" here is one of the maps produced by
  `PairingsEngine.Standings.grid_standings/1`:
  `%{player:, games:, points:, extra_points:, total:, rank:, tiebreaks:}`.
  """

  alias PairingsEngine.Standings

  @doc """
  One row per game in `entry.games` (sorted by round), describing the
  opponent and the outcome for display.
  """
  def rows(entry, by_id, tournament) do
    entry.games
    |> Enum.sort_by(& &1.round)
    |> Enum.map(&row(&1, entry, by_id, tournament))
  end

  defp row(game, entry, by_id, tournament) do
    opponent = opponent_entry(game, by_id)
    own_before = points_before(entry.games, game.round)
    opp_before = opponent && points_before(opponent.games, game.round)

    %{
      round: game.round,
      opponent_pairing_number: opponent && opponent.player.pairing_number,
      opponent_federation: opponent && opponent.player.federation,
      opponent_title: opponent && opponent.player.title,
      opponent_name: opponent && opponent.player.name,
      opponent_elo: opponent && opponent_rating(opponent.player),
      # `rank_score/2`, not `.total`. The two differ by a player's
      # administrative extra points, and a tournament only ranks on those
      # when it opted in - which it does not by default. Reading `.total`
      # here showed an opponent a score the standings table would deny,
      # for any player carrying extra points in an ordinary tournament.
      # `Standings.rank_score/2`'s own doc calls reading `.total` directly
      # "almost always a bug", and the footer of this very function already
      # uses the right one for the card owner's own side.
      opponent_total: opponent && Standings.rank_score(opponent, tournament),
      result: result_label(game, tournament),
      colour: colour_label(game),
      float: float_symbol(own_before, opp_before)
    }
  end

  defp opponent_entry(%{opponent_id: nil}, _by_id), do: nil
  defp opponent_entry(%{opponent_id: id}, by_id), do: Map.get(by_id, id)

  @doc "Sum of `games`' points for rounds strictly before `round`."
  def points_before(games, round) do
    games
    |> Enum.filter(&(&1.round < round))
    |> Enum.map(& &1.points)
    |> Enum.sum()
  end

  @doc """
  Rating shown for an opponent: national rating if set (> 0), FIDE rating
  otherwise (mirrors `PairingsEngine.Tournaments.Player.rating/1`, but with
  the opposite fallback order - SWAR's card prefers the national rating).
  """
  def opponent_rating(%{national_rating: n}) when is_integer(n) and n > 0, do: n
  def opponent_rating(%{fide_rating: f}), do: f || 0

  @doc """
  Result label for a single game record, from the point of view of the
  player the game record belongs to:

    * `"1"` / `"½"` / `"0"` - an actual result over the board
    * `"1FF"` / `"0FF"` - a forfeit win/loss (opponent existed, game unplayed)
    * `"1 bye"` / `"½ bye"` / `"0 bye"` - a bye (no opponent)
    * `""` - round not played and none of the above (e.g. still to be paired)

  A bye row is labelled by its KIND, via the `:bye_type` key
  `PairingsEngine.Standings` carries on every bye record (the `byes`-table
  row's own type, or `"pairing-allocated"` for a real `Pairing` row with
  `result: "bye"`):

    * `"requested-half"` → `"½ bye"`, `"requested-zero"`/`"absent"` →
      `"0 bye"` - always, regardless of the points actually awarded. Under
      custom scoring the awarded value can coincide with a different kind's
      usual value (e.g. SWAR 3-2-1 presence points paying a requested-zero
      bye exactly `points_draw`), and inferring the label back from the
      points then lies about what the row IS. The points themselves still
      show truthfully in the card's totals.
    * `"pairing-allocated"` (and, defensively, a record with no `:bye_type`
      at all) → the point-value heuristic below: `"½ bye"`/`"0 bye"` when
      the awarded points equal `points_draw`/`points_loss`, `"1 bye"`
      otherwise. For a pairing-allocated bye that heuristic is the right
      shape - the number tracks what the bye actually pays (e.g. `"½ bye"`
      for a club paying half-point pairing byes).
  """
  def result_label(%{opponent_id: nil} = game, tournament) do
    case Map.get(game, :bye_type) do
      # SWAR-imported rows carry the kind the FILE stated, and those two
      # kinds have fixed values there, so they keep fixed labels.
      "requested-half" -> "½ bye"
      "requested-zero" -> "0 bye"
      # Everything this app records is an "absent" row, and what it pays
      # depends on the tournament and on how many the player has already
      # had - "0 bye" was right only while nothing could pay anything else.
      #
      # Labelled from the value ITSELF rather than by comparing it against
      # the tournament's win/draw/loss, because an absence award is a free
      # number and need not equal any of them: a half point in a 2/1/0
      # tournament matches neither the draw nor the loss, and
      # `points_bye_label/2` would fall through and call it "1 bye".
      "absent" -> absence_label(game.points)
      _allocated_or_unknown -> points_bye_label(game.points, tournament)
    end
  end

  def result_label(%{played: false, voluntary: false, points: points}, tournament) do
    if points >= tournament.points_win, do: "1FF", else: "0FF"
  end

  def result_label(%{played: true, points: points}, tournament) do
    cond do
      points >= tournament.points_win -> "1"
      points <= tournament.points_loss -> "0"
      true -> "½"
    end
  end

  def result_label(_game, _tournament), do: ""

  defp absence_label(points) do
    cond do
      points == 0.0 -> "0 bye"
      points == 0.5 -> "½ bye"
      points == 1.0 -> "1 bye"
      true -> "#{:erlang.float_to_binary(points / 1, decimals: 1)} bye"
    end
  end

  defp points_bye_label(points, tournament) do
    cond do
      points == tournament.points_draw -> "½ bye"
      points == tournament.points_loss -> "0 bye"
      true -> "1 bye"
    end
  end

  @doc "The colour a game record was played with, as SWAR's single-letter code."
  def colour_label(%{colour: :w}), do: "W"
  def colour_label(%{colour: :b}), do: "B"
  def colour_label(_game), do: "-"

  @doc """
  SWAR's "Flt" (float) column: `"^"` when the opponent had more points than
  this player before the round was played, `"v"` when fewer, `"-"` when
  equal or there was no opponent (bye).
  """
  def float_symbol(_own_before, nil), do: "-"

  def float_symbol(own_before, opp_before) do
    cond do
      opp_before > own_before -> "^"
      opp_before < own_before -> "v"
      true -> "-"
    end
  end

  @doc """
  Totals for the card's bottom row: the sum of the opponents' current totals
  (skipping byes, which have none) and the sum of this player's own result
  points for the rounds shown - which is just `entry.points`.
  """
  def totals(rows, entry) do
    opponent_total =
      rows
      |> Enum.map(& &1.opponent_total)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    %{opponent_total: opponent_total, own_total: entry.points}
  end

  @doc """
  Header line for the card, e.g.
  `"Ranking:1 - (N°:3) - 12345: Doe, Jane. N-Elo:1900 Club:7"`.
  Missing pieces (blank national ID, unset club number, zero national
  rating) are omitted rather than shown as empty/zero.
  """
  def header(entry) do
    p = entry.player

    id_and_name =
      case p.national_id do
        id when id in [nil, ""] -> p.name
        id -> "#{id}: #{p.name}"
      end

    ["Ranking:#{entry.rank}", "(N°:#{p.pairing_number})", "#{id_and_name}."]
    |> Enum.join(" - ")
    |> append_if(p.national_rating not in [nil, 0], " N-Elo:#{p.national_rating}")
    |> append_if(not is_nil(p.club_number), " Club:#{p.club_number}")
  end

  defp append_if(string, true, suffix), do: string <> suffix
  defp append_if(string, false, _suffix), do: string
end
