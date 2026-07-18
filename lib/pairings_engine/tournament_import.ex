defmodule PairingsEngine.TournamentImport do
  @moduledoc """
  Imports a `PairingsEngine.TournamentExport` envelope (already JSON-decoded
  to a string-keyed map), recreating every tournament it describes as a
  brand-new tournament owned by the importing user — fresh ids throughout,
  every internal foreign key (team ids referenced by players; player ids
  referenced by pairings, byes, forbidden pairings) remapped inside a single
  transaction via an old-id -> new-id map built as each record is inserted.

  See `docs/import-export.md` for the envelope format and
  `PairingsEngine.TournamentExport` for the inverse.
  """

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Tournaments.{Tournament, Team, Player, Round, Pairing}

  # Kept as literals (rather than referencing PairingsEngine.TournamentExport
  # here) so the two modules have no compile-time dependency on each other;
  # `PairingsEngine.TournamentExport.format/0` and `.version/0` return the
  # same values and both are covered by round-trip tests.
  @format "openpairings-export"
  @version 1

  @doc """
  Imports every tournament in `data` (a JSON-decoded export envelope) as new
  tournaments owned by `scope`'s user. Returns `{:ok, [%Tournament{}, ...]}`
  on success (broadcasting the user's tournament-list change once, after
  commit) or `{:error, reason}` — `reason` is a human-readable string safe
  to show directly in a flash. Never raises: a malformed envelope, a bad
  format/version tag, or an invalid record anywhere inside it rolls the
  whole import back and comes back as `{:error, _}`, not a crash.
  """
  def import(data, %Scope{} = scope) when is_map(data) do
    cond do
      Map.get(data, "format") != @format ->
        {:error, "This file is not an OpenPairings export (unrecognized format)."}

      Map.get(data, "version") != @version ->
        {:error, "Unsupported export version #{inspect(Map.get(data, "version"))}."}

      not valid_tournaments_list?(data) ->
        {:error, "This export file contains no tournaments to import."}

      true ->
        do_import(Map.fetch!(data, "tournaments"), scope)
    end
  end

  def import(_invalid, %Scope{}), do: {:error, "This file is not a valid OpenPairings export."}

  defp valid_tournaments_list?(data) do
    case Map.get(data, "tournaments") do
      [_ | _] -> true
      _ -> false
    end
  end

  # Same after-commit, outside-suppression pattern as `PairingsEngine.SwarImport`:
  # imported rounds/results already carry whatever status the export
  # snapshotted, but the round-trip should stand on its own — re-derive
  # each tournament's status from what actually landed in the database
  # (after the transaction commits, so the query sees the imported data;
  # outside `with_broadcast_suppressed`, so a real status change still
  # broadcasts) rather than trust the imported `status` field.
  defp do_import(tournaments, scope) do
    result =
      Tournaments.with_broadcast_suppressed(fn ->
        Repo.transaction(fn -> Enum.map(tournaments, &import_tournament!(&1, scope)) end)
      end)

    case result do
      {:ok, imported} ->
        Enum.each(imported, &Tournaments.broadcast_tournament_change(&1.id, :tournament))
        Tournaments.broadcast_user_tournaments(scope.user.id)
        refreshed = Enum.map(imported, &Tournaments.refresh_status!(&1.id))
        {:ok, refreshed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## ---------- per-tournament import (runs inside the transaction) ----------

  defp import_tournament!(t_data, _scope) when not is_map(t_data) do
    Repo.rollback("Malformed tournament entry in export file.")
  end

  defp import_tournament!(t_data, scope) do
    t_attrs = fetch_map!(t_data, "tournament")

    tournament =
      %Tournament{user_id: scope.user.id}
      |> Tournament.changeset(t_attrs)
      |> insert!()

    team_map = import_teams!(tournament, list(t_data, "teams"))
    player_map = import_players!(tournament, list(t_data, "players"), team_map)
    import_rounds!(tournament, list(t_data, "rounds"), player_map)
    import_byes!(tournament, list(t_data, "byes"), player_map)
    import_forbidden_pairings!(tournament, list(t_data, "forbidden_pairings"), player_map)

    tournament
  end

  defp import_teams!(tournament, teams) do
    Map.new(teams, fn t ->
      new_team = %Team{tournament_id: tournament.id} |> Team.changeset(t) |> insert!()
      {Map.get(t, "id"), new_team.id}
    end)
  end

  defp import_players!(tournament, players, team_map) do
    Map.new(players, fn p ->
      attrs = Map.put(p, "team_id", Map.get(team_map, Map.get(p, "team_id")))
      new_player = %Player{tournament_id: tournament.id} |> Player.changeset(attrs) |> insert!()
      {Map.get(p, "id"), new_player.id}
    end)
  end

  defp import_rounds!(tournament, rounds, player_map) do
    Enum.each(rounds, fn r ->
      new_round = %Round{tournament_id: tournament.id} |> Round.changeset(r) |> insert!()

      r
      |> list("pairings")
      |> Enum.each(fn pr ->
        attrs = %{
          "board" => Map.get(pr, "board"),
          "result" => Map.get(pr, "result"),
          "white_player_id" => Map.get(player_map, Map.get(pr, "white_player_id")),
          "black_player_id" => Map.get(player_map, Map.get(pr, "black_player_id"))
        }

        %Pairing{round_id: new_round.id} |> Pairing.changeset(attrs) |> insert!()
      end)
    end)
  end

  # Schemaless tables (no Ecto schema in the app — see PairingsEngine.Pairing
  # and PairingsEngine.Standings for the same pattern on reads). A bye or
  # forbidden pairing referencing a player id that isn't in `player_map`
  # (only possible from a hand-edited/corrupt file) is silently dropped
  # rather than failing the whole import.
  defp import_byes!(tournament, byes, player_map) do
    rows =
      byes
      |> Enum.map(fn b ->
        case Map.get(player_map, Map.get(b, "player_id")) do
          nil ->
            nil

          player_id ->
            %{
              tournament_id: tournament.id,
              player_id: player_id,
              round: Map.get(b, "round"),
              type: Map.get(b, "type") || "requested-half"
            }
        end
      end)
      |> Enum.reject(&is_nil/1)

    if rows != [], do: Repo.insert_all("byes", rows)
  end

  defp import_forbidden_pairings!(tournament, forbidden, player_map) do
    rows =
      forbidden
      |> Enum.map(fn f ->
        with a when not is_nil(a) <- Map.get(player_map, Map.get(f, "player_a_id")),
             b when not is_nil(b) <- Map.get(player_map, Map.get(f, "player_b_id")) do
          %{tournament_id: tournament.id, player_a_id: a, player_b_id: b}
        else
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if rows != [], do: Repo.insert_all("forbidden_pairings", rows)
  end

  ## ---------- helpers ----------

  defp fetch_map!(data, key) do
    case Map.get(data, key) do
      m when is_map(m) -> m
      _ -> Repo.rollback("Malformed tournament entry in export file (missing \"#{key}\").")
    end
  end

  defp list(data, key) do
    case Map.get(data, key) do
      l when is_list(l) -> l
      _ -> []
    end
  end

  defp insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} ->
        record

      {:error, changeset} ->
        Repo.rollback("Could not import: " <> changeset_error_text(changeset))
    end
  end

  defp changeset_error_text(changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end
end
