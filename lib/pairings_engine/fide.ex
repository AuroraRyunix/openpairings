defmodule PairingsEngine.Fide do
  @moduledoc "Local copy of the FIDE rating list: search + sync."

  import Ecto.Query
  alias PairingsEngine.Repo
  alias PairingsEngine.Fide.FidePlayer

  def search(query) when is_binary(query) do
    query = String.trim(query)

    cond do
      String.length(query) < 2 ->
        []

      Regex.match?(~r/^\d+$/, query) ->
        case Repo.get(FidePlayer, String.to_integer(query)) do
          nil -> []
          player -> [player]
        end

      true ->
        # FIDE names are "Lastname, Firstname"; prefix search uses the name index.
        like = String.replace(query, ~r/[%_]/, "") <> "%"

        Repo.all(
          from f in FidePlayer,
            where: like(f.name, ^like),
            order_by: [asc: is_nil(f.standard_rating), desc: f.standard_rating],
            limit: 20
        )
    end
  end

  def player_count, do: Repo.aggregate(FidePlayer, :count)

  def last_sync do
    case Repo.query!("SELECT value FROM meta WHERE key = 'fide_last_sync'").rows do
      [[value]] -> value
      _ -> nil
    end
  end

  def put_last_sync do
    Repo.query!(
      "INSERT INTO meta (key, value) VALUES ('fide_last_sync', datetime('now')) " <>
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value"
    )
  end
end
