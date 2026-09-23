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
  alias PairingsEngine.Standings
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

  @doc "OpenPairings' tie-break codes, and the C.07 code each is."
  def codes, do: @codes

  @doc "C.07's spelling of an OpenPairings code."
  def c07_code(code), do: Map.fetch!(@codes, code)

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

    participants =
      for entry <- entries do
        %Participant{
          id: entry.player.id,
          tpn: entry.player.pairing_number,
          rating: rating(entry.player),
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

  defp rating(player) do
    case Player.rating(player) do
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
