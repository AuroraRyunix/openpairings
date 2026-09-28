defmodule PairingsEngine.Test.SlowExplainer do
  @moduledoc """
  A round explainer a test controls - put in place with
  `Application.put_env(:pairings_engine, :round_explainer, #{inspect(__MODULE__)})`
  (see `PairingsEngine.Pairing.Explainer`).

  The brackets do what `Application.get_env(:pairings_engine, :slow_explainer)`
  says; the one-question alternatives (`float_question/5`, `bye_question/3`)
  what `:slow_alternatives` says, so a test can let the account through and
  hold up an opened question:

    * `{:block, test_pid}` - tells `test_pid` `{:explainer_started, pid}`
      (`{:alternative_started, pid}` for a question) and waits for
      `:release` before doing the real work: the stand-in for a large
      round's minutes.
    * `:raise` - fails, as an engine error would.
    * anything else - the real explainer.

  Every call to a question is also counted (`question_calls/0`), so a test
  can tell a stored answer from one worked out again.

  Only for `async: false` tests: the settings are global.
  """
  @behaviour PairingsEngine.Pairing.Explainer

  alias PairingsEngine.Pairing.Explainer

  @impl true
  def brackets(players, pairs, opts) do
    held(:slow_explainer, :explainer_started, fn -> Explainer.brackets(players, pairs, opts) end)
  end

  @impl true
  def alternatives(players, pairs, opts), do: Explainer.alternatives(players, pairs, opts)

  @impl true
  def float_question(players, pairs, opts, group, floater) do
    count_question()

    held(:slow_alternatives, :alternative_started, fn ->
      Explainer.float_question(players, pairs, opts, group, floater)
    end)
  end

  @impl true
  def bye_question(players, pairs, opts) do
    count_question()

    held(:slow_alternatives, :alternative_started, fn ->
      Explainer.bye_question(players, pairs, opts)
    end)
  end

  @doc "How many questions have been worked out since `reset_question_calls/0`."
  def question_calls, do: :persistent_term.get({__MODULE__, :calls}, 0)

  def reset_question_calls, do: :persistent_term.put({__MODULE__, :calls}, 0)

  defp count_question, do: :persistent_term.put({__MODULE__, :calls}, question_calls() + 1)

  defp held(setting, started, work) do
    case Application.get_env(:pairings_engine, setting) do
      {:block, test_pid} ->
        send(test_pid, {started, self()})

        receive do
          :release -> :ok
        after
          30_000 -> :ok
        end

        work.()

      :raise ->
        raise "the explainer failed on purpose"

      _real ->
        work.()
    end
  end
end
