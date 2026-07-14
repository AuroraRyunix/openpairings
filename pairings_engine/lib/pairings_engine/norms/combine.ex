defmodule PairingsEngine.Norms.Combine do
  @moduledoc """
  Combines several tournaments (each with its own player list) into a single
  virtual `%Tournament{}` + player list, standing in for one FIDE report
  scope — the "categories of one festival" case for a Belgian federation
  arbiter running an IT3/FA1/IA1 for a multi-group event that OpenPairings
  itself only ever manages as separate `Tournament` rows.

  `combine/2` is pure and never touches the database: every `%Tournament{}`/
  `%Player{}` struct it's given is read as-is, and the tournament/players it
  returns are themselves plain, UNPERSISTED structs. `PairingsEngine.Norms.Forms`
  never reads `id` off either — only scalar fields — so no id needs faking.

  ## Master tournament

  Every header/schedule field on the virtual tournament (name, dates,
  round_dates, rounds_count, rate_of_play, time_control, venue, city,
  federation, officials, event_code, fide_tournament_id, ...) comes from a
  single designated "master" tournament — `master_index`, a 0-based index
  into the input list — verbatim, except `name`, which gets FIDE's own term
  for a multi-category event appended: `"<master name> Festival"`.

  Player-derived aggregates (rated/titled counts, distinct federations, ...)
  are never computed here — `PairingsEngine.Norms.Forms` already derives all
  of those purely from the player list it's handed (see its `it3_fills/2`,
  `fa1_fills/3`/`ia1_fills/3`), so simply concatenating every tournament's
  players is enough for them to "just work" through Forms unmodified.

  ## Duplicate players

  The same person entered in two of the selected tournaments is invalid —
  categories of one festival can't share a player. Identity is resolved, in
  order: a nonzero `fide_id` when present; else a non-blank `national_id`;
  else the normalized name + `birth_year`. Only a player showing up under
  more than one *tournament* (not merely more than once inside a single
  tournament's own list — that's a different, DB-level concern) counts.
  Returns every duplicate found, not just the first, as
  `{:error, {:duplicate_players, names}}` — see `error_message/1` for a
  user-facing string.
  """

  alias PairingsEngine.Tournaments.Player

  @doc """
  Combines `[{tournament, players}, ...]` into one virtual
  `{tournament, players}` pair. A single-element list passes through
  unchanged (no renaming, no player concatenation, `master_index` ignored).
  `master_index` (0-based, only consulted for 2+ tournaments) picks which
  tournament's header/schedule fields the combined result inherits — see
  the moduledoc.

  Returns `{:ok, {tournament, players}}`, or `{:error, {:duplicate_players,
  names}}` if the same player (by the identity rule in the moduledoc)
  appears in more than one of the selected tournaments.
  """
  def combine([{tournament, players}], _master_index), do: {:ok, {tournament, players}}

  def combine(pairs, master_index) when length(pairs) >= 2 do
    case duplicate_names(pairs) do
      [] ->
        {master_tournament, _master_players} = Enum.fetch!(pairs, master_index)
        virtual_players = Enum.flat_map(pairs, fn {_tournament, players} -> players end)

        virtual_tournament = %{
          master_tournament
          | id: nil,
            name: festival_name(master_tournament.name)
        }

        {:ok, {virtual_tournament, virtual_players}}

      names ->
        {:error, {:duplicate_players, names}}
    end
  end

  @doc """
  A playful, user-facing message for a `{:duplicate_players, names}` error
  from `combine/2` — names the one player for a single duplicate, or lists
  them all for several.
  """
  def error_message({:duplicate_players, [name]}) do
    "#{name} plays in two of these tournaments — the categories of one festival can't share players!"
  end

  def error_message({:duplicate_players, names}) do
    "#{Enum.join(names, ", ")} play in two of these tournaments — the categories of one festival can't share players!"
  end

  defp festival_name(name), do: "#{name} Festival"

  # A player is a cross-tournament duplicate when their identity key shows
  # up tagged with more than one distinct tournament (source index) among
  # the selected pairs — repeats *within* one tournament's own player list
  # are not this check's business (that's enforced, where it matters, at
  # the DB level when the tournament was itself created/imported).
  defp duplicate_names(pairs) do
    pairs
    |> Enum.with_index()
    |> Enum.flat_map(fn {{_tournament, players}, idx} ->
      Enum.map(players, fn player -> {identity_key(player), idx, player.name} end)
    end)
    |> Enum.group_by(fn {key, _idx, _name} -> key end)
    |> Enum.filter(fn {_key, entries} ->
      entries |> Enum.map(fn {_key, idx, _name} -> idx end) |> Enum.uniq() |> length() > 1
    end)
    |> Enum.map(fn {_key, entries} -> entries |> List.first() |> elem(2) end)
    |> Enum.sort()
  end

  defp identity_key(%Player{fide_id: fide_id}) when is_integer(fide_id) and fide_id != 0,
    do: {:fide_id, fide_id}

  defp identity_key(%Player{national_id: national_id})
       when is_binary(national_id) and national_id != "",
       do: {:national_id, national_id}

  defp identity_key(%Player{name: name, birth_year: birth_year}),
    do: {:name_birth, normalize_name(name), birth_year}

  defp normalize_name(name) do
    name |> to_string() |> String.trim() |> String.downcase() |> String.replace(~r/\s+/, " ")
  end
end
