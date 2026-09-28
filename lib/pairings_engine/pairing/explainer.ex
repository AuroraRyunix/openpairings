defmodule PairingsEngine.Pairing.Explainer do
  @moduledoc """
  The two engine calls behind a round's account, and nothing else: the
  brackets (`Ainalrami.Pairing.explain_round/3`) and the "why him and not
  me" alternatives (`Ainalrami.Alternatives`, one forced re-pairing per
  candidate - the expensive part).

  `PairingsEngine.Pairing` reaches these through
  `Application.get_env(:pairings_engine, :round_explainer, #{inspect(__MODULE__)})`
  so a test can put a slow or failing explainer in their place and watch
  what the pairing click and `PairingsEngine.ExplanationJobs` do about it.
  """

  @callback brackets(players :: list(), pairs :: list(), opts :: keyword()) :: list()
  @callback alternatives(players :: list(), pairs :: list(), opts :: keyword()) :: map()

  @behaviour __MODULE__

  @impl true
  def brackets(players, pairs, opts), do: Ainalrami.Pairing.explain_round(players, pairs, opts)

  @impl true
  def alternatives(players, pairs, opts) do
    %{
      floats: Ainalrami.Alternatives.float_alternatives(players, pairs, opts),
      bye: Ainalrami.Alternatives.bye_alternatives(players, pairs, opts)
    }
  end

  @doc false
  def impl, do: Application.get_env(:pairings_engine, :round_explainer, __MODULE__)
end
