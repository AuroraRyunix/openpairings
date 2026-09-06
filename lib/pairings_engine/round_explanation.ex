defmodule PairingsEngine.RoundExplanation do
  @moduledoc """
  Reads back what the pairing engine reported about a round, stored on
  `rounds.explanation` at pairing time by `PairingsEngine.Pairing`.

  Everything here is presentation of a RECORD. Nothing is recomputed, and
  nothing consults current standings: the point of storing the engine's own
  account is that it says what was decided at the moment it was decided,
  which a later derivation cannot recover once results are in or an arbiter
  has moved somebody.

  That same property is why `divergence/2` exists. A round can be edited
  after the engine paired it (`pairing.players_swapped`,
  `pairing.player_substituted`, `pairing.seat_filled`, ...), and a stored
  account that silently disagreed with the boards on screen would be worse
  than no account at all. So the pairs are compared, and the page is told to
  say so.
  """

  @doc """
  The stored account, with player ids resolved to players, or nil when the
  round has none (every JaVaFo round, and every round paired before the
  column existed).
  """
  def for_round(%{explanation: nil}, _players), do: nil

  def for_round(%{explanation: %{"sections" => sections}}, players) do
    by_id = Map.new(players, &{&1.id, &1})

    sections
    |> Enum.map(fn section ->
      %{
        category: section["category"],
        brackets: Enum.map(section["brackets"], &bracket(&1, by_id)),
        # Version 3: who got the pairing-allocated bye, and what every other
        # candidate would have cost. nil for an even field, and for every
        # round recorded before the key existed.
        bye: alternative(section["bye"], by_id, :holder)
      }
    end)
    |> Enum.reject(&(&1.brackets == []))
    |> case do
      [] -> nil
      resolved -> resolved
    end
  end

  def for_round(_round, _players), do: nil

  defp bracket(bracket, by_id) do
    %{
      group: bracket["group"],
      mdps: names(bracket["mdps"], by_id),
      residents: names(bracket["residents"], by_id),
      floats: names(bracket["floats"], by_id),
      pairs:
        Enum.map(bracket["pairs"] || [], fn [a, b] -> {player(a, by_id), player(b, by_id)} end),
      edge_count: bracket["edge_count"],
      edges: Enum.map(bracket["edges"] || [], &edge(&1, by_id)),
      rungs: Enum.map(bracket["rungs"] || [], &{&1["label"], &1["value"]}),
      # Version 2 of the record. A version-1 round has none of these keys and
      # reads as empty, which the panel renders as "not recorded" rather than
      # inventing a state it does not have.
      heterogeneous?: bracket["heterogeneous"] || false,
      s1: names(bracket["s1"], by_id),
      s2: names(bracket["s2"], by_id),
      states: states(bracket["states"], by_id),
      exclusions: exclusions(bracket["exclusions"], by_id),
      # Version 3: for each player who floated out, a verdict on every other
      # member floating instead.
      float_alternatives:
        (bracket["float_alternatives"] || [])
        |> Enum.map(&alternative(&1, by_id, :floater))
        |> Enum.reject(&is_nil/1)
    }
  end

  @outcomes ~w(same worse better tie incomparable impossible ineligible)
  @bye_reasons ~w(pairing_bye forfeit_win full_point_bye)

  # One "why him and not me" record - a float's or the bye's - with the
  # subject resolved under `subject_key` (`:floater` or `:holder`).
  defp alternative(nil, _by_id, _subject_key), do: nil

  defp alternative(entry, by_id, subject_key) do
    subject = player(entry[Atom.to_string(subject_key)], by_id)

    cond do
      is_nil(subject) ->
        nil

      entry["skipped"] ->
        %{
          subject_key => subject,
          skipped: entry["skipped"],
          count: entry["count"],
          candidates: []
        }

      true ->
        %{
          subject_key => subject,
          skipped: nil,
          group: entry["group"],
          candidates:
            (entry["candidates"] || [])
            |> Enum.map(&candidate(&1, by_id))
            |> Enum.reject(&is_nil(&1.player))
        }
    end
  end

  defp candidate(c, by_id) do
    %{
      player: player(c["player"], by_id),
      outcome: if(c["outcome"] in @outcomes, do: String.to_atom(c["outcome"]), else: :unknown),
      reason: reason(c["reason"]),
      at: differs(c["at"]),
      fate: fate(c["fate"], by_id),
      stayed: c["stayed"]
    }
  end

  defp reason(nil), do: nil
  defp reason(r) when r in @bye_reasons, do: String.to_atom(r)
  defp reason(r), do: r

  defp differs(nil), do: nil

  defp differs(at) do
    %{
      group: at["group"],
      label: at["label"],
      actual: at["actual"],
      alternative: at["alternative"],
      lex: at["lex"] && String.to_atom(at["lex"])
    }
  end

  defp fate(nil, _by_id), do: nil
  defp fate(f, by_id), do: %{opponent: player(f["opponent"], by_id), score: f["score"]}

  # A player's colour and float state at the moment of pairing, with the
  # player resolved. `class` comes back as the atom the engine used, so the
  # panel can pattern-match on it; the strings are what JSON could carry.
  defp states(nil, _by_id), do: []

  defp states(states, by_id) do
    states
    |> Enum.map(fn s ->
      %{
        player: player(s["player"], by_id),
        colours: s["colours"] || [],
        whites: s["whites"],
        blacks: s["blacks"],
        difference: s["difference"],
        preference: s["preference"],
        class: colour_class(s["class"]),
        repeated: s["repeated"],
        floated_last_round: float_dir(s["floated_last_round"]),
        floated_round_before: float_dir(s["floated_round_before"])
      }
    end)
    |> Enum.reject(&is_nil(&1.player))
  end

  defp colour_class("absolute"), do: :absolute
  defp colour_class("strong"), do: :strong
  defp colour_class("mild"), do: :mild
  defp colour_class(_), do: :none

  defp float_dir("up"), do: :up
  defp float_dir("down"), do: :down
  defp float_dir(_), do: nil

  # A pair the absolute criteria forbade inside this bracket. `a` is the
  # better-ranked of the two, as the engine orders them.
  defp exclusions(nil, _by_id), do: []

  defp exclusions(exclusions, by_id) do
    exclusions
    |> Enum.map(fn x ->
      [a, b] = x["players"] || [nil, nil]

      %{
        a: player(a, by_id),
        b: player(b, by_id),
        reason: exclusion_reason(x["reason"]),
        round: x["round"],
        colour: x["colour"]
      }
    end)
    |> Enum.reject(&(is_nil(&1.a) or is_nil(&1.b)))
  end

  defp exclusion_reason("rematch"), do: :rematch
  defp exclusion_reason("colour"), do: :colour
  defp exclusion_reason("forbidden"), do: :forbidden
  defp exclusion_reason(_), do: :unknown

  # A round paired before per-board attribution existed simply has no
  # "edges" key, and the panel falls back to bracket totals alone.
  defp edge(edge, by_id) do
    [a, b] = edge["players"]

    rungs = Enum.map(edge["rungs"] || [], &{&1["label"], &1["value"]})
    float? = edge["kind"] == "float"

    %{
      white: player(a, by_id),
      black: player(b, by_id),
      float?: float?,
      rungs: rungs,
      gave_up: if(float?, do: [], else: gave_up(rungs))
    }
  end

  # Every criterion in `@verdicts` is phrased so that higher is better, so a
  # zero is a board where that thing was given up to pair the bracket at all.
  #
  # Only ever computed for a board INSIDE the bracket. These criteria are
  # gated on the pair being in the current bracket, so a float edge scores
  # zero on all six by construction rather than by having sacrificed
  # anything - reading those zeros as compromises would paint every floating
  # board as a disaster.
  @verdicts %{
    "C10 topscorer colour diff" => {:colour, "topscorer colour balance given up"},
    "C11 topscorer same colour x3" => {:colour, "a topscorer takes the same colour a third time"},
    "C12 colour preference" => {:colour, "colour preference denied"},
    "C13 strong colour preference" => {:colour, "strong colour preference denied"},
    "C15 upfloat repeat r-1" => {:float, "upfloated again, having upfloated last round"},
    "C17 upfloat repeat r-2" => {:float, "upfloated again, having upfloated two rounds back"}
  }

  defp gave_up(rungs) do
    for {label, 0} <- rungs, Map.has_key?(@verdicts, label) do
      {kind, text} = Map.fetch!(@verdicts, label)
      %{kind: kind, text: text, criterion: label}
    end
  end

  defp names(ids, by_id),
    do: (ids || []) |> Enum.map(&player(&1, by_id)) |> Enum.reject(&is_nil/1)

  defp player(nil, _by_id), do: nil
  defp player(id, by_id), do: Map.get(by_id, id)

  @doc """
  Whether the round on the board still matches the one the engine explained.

  Compares WHO PLAYS WHOM and nothing else. A colour swap reseats a board
  without changing the pairing decision, so it is not divergence and must
  not be reported as such - the brackets, floats and criteria all still
  describe what happened.

  Takes the round with `:pairings` preloaded. Returns `:unchanged`,
  `:no_record` when nothing was stored, or `{:changed, count}` with the
  number of explained pairs that are no longer on a board.
  """
  def divergence(%{explanation: %{"sections" => sections}, pairings: pairings})
      when is_list(pairings) do
    explained =
      sections
      |> Enum.flat_map(& &1["brackets"])
      |> Enum.flat_map(& &1["pairs"])
      |> Enum.map(&pair_key/1)
      |> MapSet.new()

    seated =
      pairings
      |> Enum.map(&pair_key([&1.white_player_id, &1.black_player_id]))
      |> MapSet.new()

    case MapSet.size(MapSet.difference(explained, seated)) do
      0 -> :unchanged
      n -> {:changed, n}
    end
  end

  def divergence(_round), do: :no_record

  defp pair_key(ids) do
    ids |> Enum.reject(&is_nil/1) |> Enum.sort() |> List.to_tuple()
  end
end
