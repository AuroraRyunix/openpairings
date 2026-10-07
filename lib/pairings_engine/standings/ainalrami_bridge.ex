defmodule PairingsEngine.Standings.AinalramiBridge do
  @moduledoc """
  OpenPairings' standings data as an `Ainalrami.Tiebreaks.Event`, so the
  tie-breaks can be computed by Ainalrami - the same code FIDE's checker
  (`ainalrami -c`) runs - instead of by `PairingsEngine.Standings`' own.

  ## Why the move, and why this module first

  FIDE's checklist for tournament programs (VCL4THP v13, Q21 and Q33) wants
  a public checker that verifies standings and has been tested against
  another engine. That checker is Ainalrami's, so the tie-breaks have to be
  there; and the program FIDE accepts should run the code FIDE checked. This
  module is the translation. Before OpenPairings switches over,
  `mix pairings.tiebreak_gate` compares the two implementations on every
  tournament in the database - any difference is a bug in one of them, and
  gets settled against C.07 before anything changes for an arbiter.

  ## The translation

  Everything the standings need is already on the entries
  `PairingsEngine.Standings` builds: each player's game records, with
  points (SWAR presence points included), whether the game was played, the
  opponent, colour, outcome and bye type. A record becomes a round kind:

    * a played game, or a forfeit won or lost against a scheduled opponent
    * a pairing-allocated bye
    * a requested half- or zero-point bye (and an `absent` round while
      `absent_counts_as_vur` is on) - the voluntary unplayed rounds
    * any other opponent-less round - an odd round robin's free round, an
      absence the tournament does not count as voluntary - as a round
      awarded as it stands (C.07 16.2.1's treatment)

  The scoring values include the presence point, when the tournament has
  one: a 3-2-1 event's draw is worth 2, and "points awarded for a draw" in
  Article 16 means that.
  """

  alias Ainalrami.Tiebreaks.Event
  alias Ainalrami.Tiebreaks.Event.{Participant, Round}
  alias PairingsEngine.{PeriodRatings, Standings}
  alias PairingsEngine.Tournaments.Player

  # OpenPairings' codes and C.07's spelling of the same tie-break.
  @codes %{
    "BH" => "BH",
    "BHC1" => "BH/C1",
    "BHC2" => "BH/C2",
    "MBH" => "BH/M1",
    "SB" => "SB",
    "DE" => "DE",
    "WIN" => "WIN",
    "WON" => "WON",
    "BPG" => "BPG",
    "PS" => "PS",
    "KS" => "KS",
    "ARO" => "ARO",
    "AROC1" => "ARO/C1"
  }

  # The tie-breaks added for FIDE's checklist (VCL4THP Q104, Q199) are named
  # as C.07 spells them, so the code stored in a tournament, the one in a
  # TRF `202` line and Ainalrami's are the same string.
  @c07_spelled ~w(AOB AOB/F APPO APRO ARO/C2 ARO/M1 ARO/M2 BH/M2 BWG DE/P FB FB/C1 FB/C2
                  FB/M1 FB/M2 KS/L1 KS/L2 KS/L-1 KS/L-2 PS/C1 PS/C2 PTP REP RTNG RTNG/R
                  SB/C1 SB/C2 STD TPN TPN/R TPR)

  @codes Enum.reduce(@c07_spelled, @codes, &Map.put(&2, &1, &1))

  @doc "OpenPairings' tie-break codes, and the C.07 code each is."
  def codes, do: @codes

  @doc "C.07's spelling of an OpenPairings code."
  def c07_code(code), do: Map.fetch!(@codes, code)

  @doc """
  C.07's spelling of `code` for `tournament`: a rating-based tie-break
  (Article 10) carries `/U<rating>` when the tournament says what an unrated
  player counts as (`tiebreak_unrated_rating`), which is how Ainalrami - and
  a checker reading the TRF - is told not to drop it.
  """
  def c07_code(code, tournament) do
    c07 = c07_code(code)

    case Map.get(tournament, :tiebreak_unrated_rating) do
      n when is_integer(n) and n >= 0 ->
        if PairingsEngine.Tiebreaks.rating_based?(code), do: c07 <> "/U#{n}", else: c07

      _ ->
        c07
    end
  end

  @doc """
  The event for `entries` (as `PairingsEngine.Standings` builds them) of
  `tournament`, counting `rounds` rounds.
  """
  def event(entries, tournament, rounds) do
    presence = Standings.win_points(tournament) - tournament.points_win

    points = %{
      win: tournament.points_win + presence,
      draw: tournament.points_draw + presence,
      loss: tournament.points_loss + presence
    }

    # One rating per player: for a tournament lasting more than 30 days,
    # the one valid in the round the arbiter chose, the first by default
    # (C.07 Article 10, VCL4THP Q215-Q216; `PeriodRatings`).
    tiebreak_round = PeriodRatings.tiebreak_round(tournament)

    participants =
      for entry <- entries do
        %Participant{
          id: entry.player.id,
          tpn: entry.player.pairing_number,
          rating:
            entry.player
            |> PeriodRatings.at_round(tiebreak_round, tournament)
            |> rating(tournament),
          rounds:
            entry.games
            |> Enum.filter(&(&1.round <= rounds))
            |> Map.new(&{&1.round, round(&1, points)})
        }
      end

    Event.new(participants, rounds,
      points: points,
      predetermined?: tournament.pairing_system == "round_robin",
      total_rounds: tournament.rounds_count
    )
  end

  # The Tournament Rating (`Player.rating/2`): the TEC Manual's rating for
  # "rating-based tie-break calculations".
  defp rating(player, tournament) do
    case Player.rating(player, tournament) do
      r when is_integer(r) and r > 0 -> r
      _ -> nil
    end
  end

  defp round(game, points) do
    kind =
      cond do
        game.opponent_id != nil and game.played -> :played
        game.opponent_id != nil and game.outcome == :win -> :forfeit_win
        game.opponent_id != nil -> :forfeit_loss
        game.bye_type == "pairing-allocated" -> :pab
        game.voluntary and game.bye_type == "requested-half" -> :half_bye
        game.voluntary -> :zero_bye
        true -> :full_bye
      end

    %Round{
      kind: kind,
      opponent: game.opponent_id,
      colour:
        case game.colour do
          :w -> :white
          :b -> :black
          _ -> nil
        end,
      points: game.points * 1.0,
      outcome:
        case game.outcome do
          o when o in [:win, :draw, :loss] -> o
          _ -> Event.outcome(game.points * 1.0, points)
        end
    }
  end
end
