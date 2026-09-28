defmodule PairingsEngine.Test.SlowExplainer do
  @moduledoc """
  A round explainer a test controls - put in place with
  `Application.put_env(:pairings_engine, :round_explainer, #{inspect(__MODULE__)})`
  (see `PairingsEngine.Pairing.Explainer`).

  What it does is `Application.get_env(:pairings_engine, :slow_explainer)`:

    * `{:block, test_pid}` - tells `test_pid` `{:explainer_started, pid}`
      and waits for `:release` before doing the real work: the stand-in for
      the four minutes a large round's alternatives take.
    * `:raise` - fails, as an engine error would.
    * anything else - the real explainer.

  Only for `async: false` tests: the setting is global.
  """
  @behaviour PairingsEngine.Pairing.Explainer

  alias PairingsEngine.Pairing.Explainer

  @impl true
  def brackets(players, pairs, opts) do
    case Application.get_env(:pairings_engine, :slow_explainer) do
      {:block, test_pid} ->
        send(test_pid, {:explainer_started, self()})

        receive do
          :release -> :ok
        after
          30_000 -> :ok
        end

        Explainer.brackets(players, pairs, opts)

      :raise ->
        raise "the explainer failed on purpose"

      _real ->
        Explainer.brackets(players, pairs, opts)
    end
  end

  @impl true
  def alternatives(players, pairs, opts), do: Explainer.alternatives(players, pairs, opts)
end
