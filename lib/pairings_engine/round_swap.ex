defmodule PairingsEngine.RoundSwap do
  @moduledoc """
  Plays two rounds of a round robin in each other's place.

  An arbiter sometimes has to play the Berger table out of order - a hall
  booked out, a team that cannot travel that weekend - and wants the round
  NUMBERS to follow the order the rounds are actually played in: "round 4"
  on the fourth evening is whatever the table calls round 5, the standings
  "after round 4" are after the fourth evening, and every print and the
  results site list the rounds as they were played.

  So a swap exchanges the whole content of two rounds - boards, matches,
  the round robin's sitting-out byes, the stored engine account, the hand
  edits - while what belongs to the EVENING stays with its number: the
  date, the Chess960 position, and whether the round is published. Colours
  are the table's for the table round, so nobody's White changes.

  Which table round each played round is lives in
  `tournaments.rr_round_map` (`RoundRobin.table_round_number/2`): a list,
  position `n - 1` holding the table round played as round `n`, nil while
  the rounds are played in table order. The schedule, the pairing
  explanation, the hand-pairing checks and the next round paired from the
  table all go through it, so "this is Berger round 5" stays true wherever
  it is played. FIDE C.05 Annex 1's reversed last two rounds of a double
  round robin (`rr_reverse_last_two`) are part of the table itself
  (`RoundRobin.schedule/4`); the map numbers that table's rounds and is
  applied on top of it, never instead of it.

  Refused unless both rounds are result-free: no result, no forfeit, no
  postponed mark, no date played, and no bye recorded for a player who has
  a board in the round. Refused for match format (its two legs play back to
  back by definition), before the schedule exists (round 1 unpaired: the
  table's length is not known yet), and when one round is paired and the
  other is not - pair the rest of the schedule first.
  """

  import Ecto.Query
  use Gettext, backend: PairingsEngineWeb.Gettext

  alias PairingsEngine.{Repo, RoundRobin, Tournaments}
  alias PairingsEngine.Tournaments.{Match, Pairing, Round, Tournament}

  # What stays with the round NUMBER - the evening - when the content moves.
  @evening_fields [
    :date,
    :chess960_position,
    :status,
    :published_at,
    :publish_due_at,
    :results_public,
    :publish_cap
  ]

  @doc "Whether `tournament`'s rounds can be swapped at all."
  def available?(%Tournament{pairing_system: "round_robin", rr_match_format: false}), do: true
  def available?(_tournament), do: false

  @doc """
  Swaps rounds `a` and `b` of `tournament`. Returns `{:ok, tournament}`
  with the new `rr_round_map`, or `{:error, message}`.
  """
  @spec swap(Tournament.t(), integer(), integer()) :: {:ok, Tournament.t()} | {:error, String.t()}
  def swap(%Tournament{} = tournament, a, b) when is_integer(a) and is_integer(b) do
    paired = PairingsEngine.Pairing.paired_rounds_count(tournament.id)

    with :ok <- writable(tournament),
         :ok <- shape(tournament),
         :ok <- numbers(tournament, paired, a, b),
         round_a = Tournaments.get_round(tournament.id, a),
         round_b = Tournaments.get_round(tournament.id, b),
         :ok <- both_or_neither(round_a, round_b, a, b),
         :ok <- result_free(tournament, round_a),
         :ok <- result_free(tournament, round_b) do
      Repo.transaction(fn ->
        if round_a && round_b, do: move_content(tournament, round_a, round_b)
        swap_announcements(tournament.id, a, b)

        tournament
        |> Ecto.Changeset.change(rr_round_map: swapped_map(tournament, a, b))
        |> Repo.update!()
      end)
      |> case do
        {:ok, updated} ->
          Tournaments.invalidate_manual_ranking(updated.id)
          Tournaments.broadcast_tournament_change(updated.id, :rounds)
          {:ok, updated}

        {:error, _} ->
          {:error, gettext("The rounds could not be swapped.")}
      end
    end
  end

  @doc """
  `map` with the table rounds of played rounds `a` and `b` exchanged; nil
  when the result is the table's own order again.
  """
  def swapped_map(%Tournament{rr_round_map: map, rounds_count: count}, a, b) do
    length = Enum.max([count || 0, a, b, length(map || [])])
    full = RoundRobin.full_round_map(map, length)

    swapped =
      full
      |> List.replace_at(a - 1, Enum.at(full, b - 1))
      |> List.replace_at(b - 1, Enum.at(full, a - 1))

    if swapped == Enum.to_list(1..length), do: nil, else: swapped
  end

  ## ---------- refusals ----------

  defp writable(tournament) do
    case Tournaments.ensure_writable(tournament) do
      :ok -> :ok
      {:error, reason} -> {:error, Tournaments.refusal_message(reason, "swapping rounds")}
    end
  end

  defp shape(%Tournament{pairing_system: "round_robin", rr_match_format: true}),
    do:
      {:error,
       gettext(
         "A round robin in match format plays the two games of a match in consecutive rounds, so its rounds cannot be swapped."
       )}

  defp shape(%Tournament{pairing_system: "round_robin"}), do: :ok

  defp shape(_tournament),
    do: {:error, gettext("Only the rounds of a round robin can be swapped.")}

  defp numbers(_tournament, 0, _a, _b),
    do:
      {:error,
       gettext(
         "Pair the round robin first: until round 1 exists the schedule's length is not known."
       )}

  defp numbers(_tournament, _paired, same, same),
    do: {:error, gettext("Pick two different rounds.")}

  defp numbers(%Tournament{rounds_count: count}, _paired, a, b) do
    if a in 1..count//1 and b in 1..count//1,
      do: :ok,
      else: {:error, gettext("Pick two rounds from 1 to %{count}.", count: count)}
  end

  defp both_or_neither(nil, %Round{}, a, b), do: half_paired(b, a)
  defp both_or_neither(%Round{}, nil, a, b), do: half_paired(a, b)
  defp both_or_neither(_round_a, _round_b, _a, _b), do: :ok

  defp half_paired(paired, unpaired),
    do:
      {:error,
       gettext(
         "Round %{paired} is paired and round %{unpaired} is not. Pair the rest of the schedule first, then swap them.",
         paired: paired,
         unpaired: unpaired
       )}

  defp result_free(_tournament, nil), do: :ok

  defp result_free(tournament, %Round{} = round) do
    cond do
      Enum.any?(round.pairings, &decided?/1) or decided_match?(round) ->
        {:error,
         gettext(
           "Round %{round} already has results (or a forfeit, a postponed game or a date played), so it is no longer a round that can move.",
           round: round.number
         )}

      seated_bye?(tournament, round) ->
        {:error,
         gettext(
           "Round %{round} has a bye recorded for a player who has a board in it. Remove the bye first.",
           round: round.number
         )}

      true ->
        :ok
    end
  end

  defp decided?(%Pairing{} = p) do
    p.result not in [nil, ""] or not is_nil(p.postponed_by) or not is_nil(p.played_on) or
      not is_nil(p.not_played_at) or not is_nil(p.provisional_white) or
      not is_nil(p.provisional_black)
  end

  defp decided_match?(%Round{id: id}) do
    Repo.exists?(
      from m in Match,
        where:
          m.round_id == ^id and
            (not is_nil(m.forfeited_to_team_id) or m.double_forfeit == true or
               not is_nil(m.match_score_a) or not is_nil(m.match_score_b))
    )
  end

  defp seated_bye?(tournament, round) do
    seated = seated(round)

    tournament.id
    |> bye_players(round.number)
    |> Enum.any?(&MapSet.member?(seated, &1))
  end

  defp seated(%Round{pairings: pairings}) do
    pairings
    |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp bye_players(tournament_id, number) do
    Repo.all(
      from b in "byes",
        where: b.tournament_id == ^tournament_id and b.round == ^number,
        select: b.player_id
    )
  end

  ## ---------- the move ----------

  # The rows keep their ids (and so their boards, matches and everything
  # hanging off `round_id`); only the numbers trade places, through a
  # number no round has, since (tournament, number) is unique. Then the
  # evening's own fields are put back where they were.
  defp move_content(tournament, %Round{} = round_a, %Round{} = round_b) do
    a = round_a.number
    b = round_b.number

    set_number(round_a.id, -a)
    set_number(round_b.id, a)
    set_number(round_a.id, b)

    Repo.update_all(from(r in Round, where: r.id == ^round_a.id),
      set: Enum.map(@evening_fields, &{&1, Map.get(round_b, &1)})
    )

    Repo.update_all(from(r in Round, where: r.id == ^round_b.id),
      set: Enum.map(@evening_fields, &{&1, Map.get(round_a, &1)})
    )

    # The table's sitting-out byes are the round's content. A bye for a
    # seated player would be the evening's, and `result_free/2` refused
    # those, so every bye row of these two rounds moves.
    swap_numbers("byes", :round, tournament.id, a, b)
  end

  defp set_number(round_id, number),
    do: Repo.update_all(from(r in Round, where: r.id == ^round_id), set: [number: number])

  # Boards announced for a round not yet paired were the table round's.
  defp swap_announcements(tournament_id, a, b),
    do: swap_numbers("board_announcements", :round, tournament_id, a, b)

  defp swap_numbers(table, field, tournament_id, a, b) do
    rows = fn n ->
      from(x in table, where: x.tournament_id == ^tournament_id and field(x, ^field) == ^n)
    end

    Repo.update_all(rows.(a), set: [{field, -a}])
    Repo.update_all(rows.(b), set: [{field, a}])
    Repo.update_all(rows.(-a), set: [{field, b}])
  end

  @doc """
  The audit trail's account of a swap: the two rounds and the table rounds
  they now hold.
  """
  def audit_details(%Tournament{} = updated, a, b) do
    %{
      "rounds" => [a, b],
      "table_rounds" => [
        RoundRobin.table_round_number(updated, a),
        RoundRobin.table_round_number(updated, b)
      ]
    }
  end
end
