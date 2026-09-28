defmodule PairingsEngine.Pairing.Explainer do
  @moduledoc """
  The engine calls behind a round's account, and nothing else: the
  brackets (`Ainalrami.Pairing.explain_round/3`) and the "why him and not
  me" alternatives (`Ainalrami.Alternatives`, one forced re-pairing per
  candidate - the expensive part).

  The alternatives come two ways. `alternatives/3` answers every question
  of a round at once, for the arbiter's explicit "recompute" and "work it
  all out" (`PairingsEngine.Pairing.reexplain_round/2`, `deepen_round/2`).
  `float_question/5` and `bye_question/3` answer ONE question - why this
  player floated, why the bye went where it went - which is how a round
  paired since 2026-09-28 gets them: when somebody opens that question on
  the explanation page, and only then.

  `PairingsEngine.Pairing` reaches these through
  `Application.get_env(:pairings_engine, :round_explainer, #{inspect(__MODULE__)})`
  so a test can put a slow or failing explainer in their place and watch
  what the pairing click and `PairingsEngine.ExplanationJobs` do about it.
  """

  alias Ainalrami.Alternatives
  alias Ainalrami.Pairing

  @callback brackets(players :: list(), pairs :: list(), opts :: keyword()) :: list()
  @callback alternatives(players :: list(), pairs :: list(), opts :: keyword()) :: map()
  @callback float_question(
              players :: list(),
              pairs :: list(),
              opts :: keyword(),
              group :: number(),
              floater :: pos_integer()
            ) :: map() | nil
  @callback bye_question(players :: list(), pairs :: list(), opts :: keyword()) :: map() | nil

  @behaviour __MODULE__

  @impl true
  def brackets(players, pairs, opts), do: Pairing.explain_round(players, pairs, opts)

  @impl true
  def alternatives(players, pairs, opts) do
    %{
      floats: Alternatives.float_alternatives(players, pairs, opts),
      bye: Alternatives.bye_alternatives(players, pairs, opts)
    }
  end

  @impl true
  def bye_question(players, pairs, opts), do: Alternatives.bye_alternatives(players, pairs, opts)

  @doc """
  "Why did `floater` float out of the `group` bracket, and not somebody
  else" - the one entry `Ainalrami.Alternatives.float_alternatives/3` would
  have produced for that floater, without the forced searches for every
  other floater of the round. nil when that player did not float out of
  that bracket.

  Ainalrami answers the question only for every floater at once, and a
  large round has dozens; this is the same computation for one of them,
  built on the engine's public calls (`pair_next_round/2`,
  `explain_round/3`, `Alternatives.compare/2`). The shape and every value
  must stay what `float_alternatives/3` returns -
  `test/pairings_engine/alternatives_on_demand_test.exs` holds the two
  side by side, so an engine upgrade that changes one fails there first.
  """
  @impl true
  def float_question(players, pairs, opts, group, floater) do
    {cap, opts} = Keyword.pop(opts, :max_candidates, Alternatives.max_candidates())
    actual = Pairing.explain_round(players, pairs, quiet(opts))

    with false <- floater == bye_holder(pairs),
         %{} = bracket <- Enum.find(actual, &(&1.group == group and floater in &1.floats)) do
      candidates = bracket.order -- [floater]

      if over_cap?(candidates, cap) do
        %{group: bracket.group, floater: floater, skipped: :too_many, count: length(candidates)}
      else
        %{
          group: bracket.group,
          floater: floater,
          candidates:
            Enum.map(candidates, fn y ->
              forced = for m <- bracket.order, m != y, do: [y, m]
              attempt(players, opts, actual, y, forced, floater)
            end)
        }
      end
    else
      _ -> nil
    end
  end

  # From here down: `Ainalrami.Alternatives`' own private steps, as of
  # Ainalrami 0.33.0, for `float_question/5`. Kept verbatim in behaviour.

  defp quiet(opts), do: Keyword.put(opts, :bye_passed_over, false)

  defp over_cap?(_candidates, :all), do: false
  defp over_cap?(candidates, cap) when is_integer(cap), do: length(candidates) > cap

  defp attempt(players, opts, actual, y, forced, displaced) do
    forced_opts =
      Keyword.put(opts, :forbidden_pairs, (Keyword.get(opts, :forbidden_pairs) || []) ++ forced)

    try do
      alt_pairs = Pairing.pair_next_round(players, forced_opts)
      alt = Pairing.explain_round(players, alt_pairs, quiet(opts))
      verdict = Alternatives.compare(actual, alt)

      %{
        rank: y,
        outcome: outcome(verdict),
        differs_at: differs_at(verdict),
        fate: fate(alt_pairs, players, y),
        floater_stayed?: stayed?(alt, displaced)
      }
    rescue
      e in Pairing.NoValidPairingError ->
        %{rank: y, outcome: :impossible, reason: Exception.message(e)}
    end
  end

  defp outcome(:identical), do: :same
  defp outcome({:worse, _, _, _, _}), do: :worse
  defp outcome({:better, _, _, _, _}), do: :better
  defp outcome({:tie, _, _}), do: :tie
  defp outcome({:incomparable, _}), do: :incomparable

  defp differs_at({:worse, group, label, ov, tv}),
    do: %{group: group, label: label, actual: ov, alternative: tv}

  defp differs_at({:better, group, label, ov, tv}),
    do: %{group: group, label: label, actual: ov, alternative: tv}

  defp differs_at({:tie, group, pick}), do: %{group: group, label: nil, lex: pick}
  defp differs_at({:incomparable, group}), do: %{group: group, label: nil}
  defp differs_at(:identical), do: nil

  defp fate(alt_pairs, players, y) do
    points = Map.new(players, &{&1.rank, &1.points})

    opponent =
      Enum.find_value(alt_pairs, fn
        {^y, other} -> {:ok, other}
        {other, ^y} -> {:ok, other}
        _ -> nil
      end)

    case opponent do
      {:ok, nil} -> %{opponent: nil, score: nil}
      {:ok, other} -> %{opponent: other, score: Map.get(points, other)}
      nil -> %{opponent: nil, score: nil}
    end
  end

  defp stayed?(alt_report, rank) do
    Enum.any?(alt_report, fn bracket ->
      rank in bracket.order and rank not in bracket.floats
    end)
  end

  defp bye_holder(pairs), do: Enum.find_value(pairs, fn {w, b} -> if is_nil(b), do: w end)

  @doc false
  def impl, do: Application.get_env(:pairings_engine, :round_explainer, __MODULE__)
end
