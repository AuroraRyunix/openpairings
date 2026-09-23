defmodule Mix.Tasks.Pairings.Vcl do
  @shortdoc "Shows how far OpenPairings is from passing FIDE's VCL4THP checklist"

  @moduledoc """
  Walks FIDE's VCL4THP checklist with our own answers and reports where the
  verification would stop, what it would cost, and what is still unchecked.

      mix pairings.vcl            # the summary
      mix pairings.vcl --write    # also regenerate docs/vcl4thp-tracker.md

  ## Why a walk and not a count

  The checklist is not a list of 225 independent items. Every answer leads to
  a named next question, so which questions count at all depends on the
  answers before them - a program without its own engine never sees the
  checker questions, a program that locks the round count never sees the
  four questions about changing it. Each answer has one of three outcomes:
  carry on, a penalty percentage (they add up, and over 100% fails), or a
  failure, where FIDE's verification stops. So the only honest summary is
  the one FIDE would compute: follow our answers from question 1.

  The walk does not stop at the first failure the way FIDE's would. It
  reports that failure first, then carries on past it, so the list of
  failures is everything standing between us and a pass rather than only
  the first thing.

  ## The data

  `docs/vcl4thp/tracker.json`: per question, what it asks in our own words,
  both outcomes as the draft gives them, our answer, and a status - `met`
  (checked, with evidence in the note), `gap` (checked, not met) or `check`
  (our best reading, not yet verified). The draft itself is a TEC
  consultation document and is not copied into the repository; the question
  numbers are what tie the two together.

  Edit the JSON, then run with `--write`. `pairings_vcl_test.exs` fails when
  the generated document is out of date with the data.
  """

  use Mix.Task

  @data "docs/vcl4thp/tracker.json"
  @doc_path "docs/vcl4thp-tracker.md"

  @impl Mix.Task
  def run(args) do
    tracker = load()
    walk = walk(tracker)

    Mix.shell().info(summary(tracker, walk))

    if "--write" in args do
      File.write!(@doc_path, document(tracker, walk))
      Mix.shell().info("wrote #{@doc_path}")
    end
  end

  @doc false
  def load(path \\ @data), do: path |> File.read!() |> Jason.decode!()

  @doc """
  Follows our answers from question 1. Returns the questions on the path, the
  failures on it (in order) and the penalty percentages it collects.
  """
  def walk(%{"questions" => questions}) do
    by_q = Map.new(questions, &{&1["q"], &1})
    step(1, by_q, MapSet.new(), %{path: [], fails: [], penalties: []})
  end

  defp step(q, by_q, seen, acc) when is_integer(q) do
    case {Map.fetch(by_q, q), MapSet.member?(seen, q)} do
      {{:ok, question}, false} ->
        branch = if question["answer"] == "Y", do: question["yes"], else: question["no"]

        acc = %{acc | path: [q | acc.path]}

        acc =
          case branch["outcome"] do
            "fail" -> %{acc | fails: [q | acc.fails]}
            "penalty" -> %{acc | penalties: [{q, branch["penalty"]} | acc.penalties]}
            _ -> acc
          end

        # A failure with no next question: FIDE would stop; the walk carries
        # on with the following number so the rest of the gaps still show.
        next =
          case branch["next"] do
            "end" -> :end
            nil -> q + 1
            n -> n
          end

        step(next, by_q, MapSet.put(seen, q), acc)

      _ ->
        finish(acc)
    end
  end

  defp step(_end, _by_q, _seen, acc), do: finish(acc)

  defp finish(acc) do
    %{
      path: Enum.reverse(acc.path),
      fails: Enum.reverse(acc.fails),
      penalties: Enum.reverse(acc.penalties)
    }
  end

  defp penalty_total(walk), do: walk.penalties |> Enum.map(&elem(&1, 1)) |> Enum.sum()

  defp status_counts(questions),
    do: Enum.frequencies_by(questions, & &1["status"])

  defp summary(%{"questions" => questions} = tracker, walk) do
    counts = status_counts(questions)
    on_path = Enum.filter(questions, &(&1["q"] in walk.path))
    path_counts = status_counts(on_path)

    first =
      case walk.fails do
        [] -> "none - no answer on our path is a failure"
        [q | _] -> "Q#{q} - FIDE's verification would stop here"
      end

    """
    VCL4THP #{tracker["version"]}, answers reviewed #{tracker["reviewed"]}
      Questions on our path:  #{length(walk.path)} of #{length(questions)}
      First failure:          #{first}
      Failures on the path:   #{length(walk.fails)}#{fails_line(walk.fails)}
      Penalties on the path:  #{penalty_total(walk)}% (over 100% fails)
      Answers:                #{counts["met"] || 0} met, #{counts["gap"] || 0} gaps, #{counts["check"] || 0} still to check
      On the path:            #{path_counts["met"] || 0} met, #{path_counts["gap"] || 0} gaps, #{path_counts["check"] || 0} still to check
    """
  end

  defp fails_line([]), do: ""
  defp fails_line(fails), do: " (" <> Enum.map_join(fails, ", ", &"Q#{&1}") <> ")"

  @doc false
  def document(%{"questions" => questions} = tracker, walk) do
    on_path = MapSet.new(walk.path)

    sections =
      questions
      |> Enum.chunk_by(& &1["section"])
      |> Enum.map_join("\n", &section(&1, on_path))

    """
    # FIDE VCL4THP tracker

    <!-- Generated by `mix pairings.vcl --write` from docs/vcl4thp/tracker.json.
         Edit the JSON, not this file. -->

    Where OpenPairings stands against FIDE's Verification Checklist for
    Tournament Handler Programs, version #{tracker["version"]}. Answers
    reviewed #{tracker["reviewed"]}. The goal before applying for a TAPC:
    no failure and no penalty on our path, and every answer checked.

    Every question is asked **in FIDE mode**: anything only possible after
    leaving FIDE mode does not count against us. So one way to answer a
    question well is to make the behaviour it asks about a departure from
    FIDE mode (`PairingsEngine.Compliance`).

    ## Summary

    ```
    #{summary(tracker, walk) |> String.trim_trailing()}
    ```

    - **met**: checked, evidence in the note.
    - **gap**: checked, not met.
    - **check**: our best reading, not verified yet.
    - **Outcome** is what our current answer costs: ok, a penalty, or
      **FAIL** (verification stops). Questions marked "-" are not on our path
      with today's answers.

    #{sections}
    """
  end

  defp section([first | _] = questions, on_path) do
    rows = Enum.map_join(questions, "\n", &row(&1, on_path))

    """
    ## #{first["section"]}

    | Q | Asks | Answer | Status | Outcome | Note |
    |---|---|---|---|---|---|
    #{rows}
    """
  end

  defp row(question, on_path) do
    branch = if question["answer"] == "Y", do: question["yes"], else: question["no"]

    outcome =
      cond do
        not MapSet.member?(on_path, question["q"]) -> "-"
        branch["outcome"] == "fail" -> "**FAIL**"
        branch["outcome"] == "penalty" -> "-#{branch["penalty"]}%"
        true -> "ok"
      end

    "| #{question["q"]} | #{cell(question["asks"])} | #{question["answer"]} | " <>
      "#{question["status"]} | #{outcome} | #{cell(question["note"])} |"
  end

  defp cell(text), do: text |> to_string() |> String.replace("|", "\\|")
end
