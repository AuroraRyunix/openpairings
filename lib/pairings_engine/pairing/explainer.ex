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
  else" - `Ainalrami.Alternatives.float_alternative/5`: the one entry
  `float_alternatives/3` would have produced for that floater, without the
  forced searches for every other floater of the round. nil when that
  player did not float out of that bracket.
  """
  @impl true
  def float_question(players, pairs, opts, group, floater),
    do: Alternatives.float_alternative(players, pairs, group, floater, opts)

  @doc false
  def impl, do: Application.get_env(:pairings_engine, :round_explainer, __MODULE__)
end
