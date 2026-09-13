defmodule PairingsEngine.AuditActionCodes do
  @moduledoc """
  Walks every `.ex` file under `lib/` for a `PairingsEngine.Audit.log/4` or
  `.log_system/3` call site (aliased `Audit.log(...)` or fully-qualified
  `PairingsEngine.Audit.log(...)`, either spelling) and works out which
  action codes the app can write *today*.

  Shared by two guards that both need the same answer to "what does the
  app currently record":

    * `audit_describe_test.exs` - every recorded code has a `describe/2`
      sentence;
    * `audit_live_test.exs` - every recorded code is in exactly one
      `AuditLive` category filter (or documented as fitting none).

  Parses with `Code.string_to_quoted!/1` rather than regex, so a call
  wrapped across several lines, or reformatted by `mix format`, is still
  found the same way.

  Most call sites pass the action as a bare string literal - trivial to
  read off the AST. A handful build it from a variable, a module
  attribute, or a helper function instead; working out what THOSE can
  hold means reading the surrounding code, not just parsing it, so they
  are listed by hand in `@non_literal_call_sites` below, keyed by the
  argument's own source text (`Macro.to_string/1` of the AST node) rather
  than a line number, so the list survives reformatting elsewhere in the
  file. Both guard tests assert this list exactly matches what parsing
  finds today, so a new non-literal call site cannot go undocumented
  silently - it fails the test that reads this module until someone adds
  it here.
  """

  @lib_glob "lib/**/*.ex"

  @non_literal_call_sites %{
    {"lib/pairings_engine_web/live/history_live.ex", "@manual_trigger"} => ~w(snapshot.manual),
    {"lib/pairings_engine_web/live/pairings_live.ex",
     "if updated.hidden do\n  \"pairing.hidden\"\nelse\n  \"pairing.unhidden\"\nend"} =>
      ~w(pairing.hidden pairing.unhidden),
    {"lib/pairings_engine_web/live/pairings_live.ex", "action"} =>
      ~w(pairing.result_entered pairing.result_changed),
    {"lib/pairings_engine_web/live/pairings_live.ex", "audit_action(confirm.kind)"} =>
      ~w(pairing.players_swapped pairing.player_substituted pairing.seat_vacated
         pairing.bye_awarded pairing.seat_filled pairing.pool_paired pairing.deleted),
    {"lib/pairings_engine_web/live/mobile_results_live.ex", "action"} =>
      ~w(pairing.result_cleared pairing.result_entered pairing.result_changed),
    {"lib/pairings_engine/tournaments.ex", "@forced_unlock_action"} =>
      ~w(tournament.handoff_forced)
  }

  @doc """
  Every `Audit.log/4` / `Audit.log_system/3` call site found under `lib/`,
  as `%{file:, arg_source:, writer:, resolved:}` maps - `resolved` is
  `{:literal, code}` or `:non_literal`. One entry per call site, not per
  code: a call site whose action is a variable with two possible values
  contributes one entry here and two codes wherever codes are read off it.
  """
  def call_sites do
    @lib_glob
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(&file_call_sites/1)
  end

  @doc "Every action code a current call site can write, literal or not."
  def recorded_codes do
    call_sites() |> Enum.flat_map(&codes_for/1) |> Enum.uniq() |> Enum.sort()
  end

  @doc """
  Recorded codes written through `Audit.log_system/3` - always
  `tournament_id: nil`, so they can never reach `AuditLive`'s
  tournament-scoped queries and are exempt from needing a category there.
  """
  def machine_wide_codes do
    call_sites()
    |> Enum.filter(&(&1.writer == :log_system))
    |> Enum.flat_map(&codes_for/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Recorded codes written through `Audit.log/4` - tournament-scoped."
  def tournament_scoped_codes do
    call_sites()
    |> Enum.filter(&(&1.writer == :log))
    |> Enum.flat_map(&codes_for/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "The `@non_literal_call_sites` keys - what the documented list covers."
  def documented_non_literal_sites, do: @non_literal_call_sites |> Map.keys() |> Enum.sort()

  @doc "The `{file, arg_source}` of every call site parsing found non-literal."
  def found_non_literal_sites do
    call_sites()
    |> Enum.filter(&(&1.resolved == :non_literal))
    |> Enum.map(&{&1.file, &1.arg_source})
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp codes_for(%{resolved: {:literal, code}}), do: [code]

  defp codes_for(%{resolved: :non_literal, file: file, arg_source: src}),
    do: Map.fetch!(@non_literal_call_sites, {file, src})

  defp file_call_sites(path) do
    ast =
      path
      |> File.read!()
      |> Code.string_to_quoted!()

    {_ast, sites} = Macro.prewalk(ast, [], &collect(&1, &2, path))
    sites
  end

  # Matches `Audit.log(...)` / `Audit.log_system(...)` (aliased) and
  # `PairingsEngine.Audit.log(...)` (fully qualified, used by
  # `pairing_explain_live.ex`) alike - both compile to a remote call whose
  # module alias list ENDS in `Audit`.
  defp collect({{:., _, [{:__aliases__, _, mod_parts}, fun]}, _, args} = node, acc, path)
       when fun in [:log, :log_system] do
    if List.last(mod_parts) == :Audit do
      case action_arg(fun, args) do
        {:ok, action_ast} ->
          site = %{
            file: path,
            arg_source: Macro.to_string(action_ast),
            writer: fun,
            resolved: resolve(action_ast)
          }

          {node, [site | acc]}

        :error ->
          {node, acc}
      end
    else
      {node, acc}
    end
  end

  defp collect(node, acc, _path), do: {node, acc}

  # `log/4` and `log_system/3` both default their last (`details`) argument,
  # so a call site may legally omit it - the action is always the
  # second-to-last of whatever arity the call actually used.
  defp action_arg(:log, args) when length(args) in [3, 4], do: {:ok, Enum.at(args, 2)}
  defp action_arg(:log_system, args) when length(args) in [2, 3], do: {:ok, Enum.at(args, 1)}
  defp action_arg(_fun, _args), do: :error

  defp resolve(code) when is_binary(code), do: {:literal, code}
  defp resolve(_other), do: :non_literal
end
