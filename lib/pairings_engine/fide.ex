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
        # FIDE names are stored "Lastname, Firstname". Match every whitespace/
        # comma-separated token as a substring (case-insensitive), in any
        # order, so "burssens, jorian", "burssens jorian", "jorian burssens"
        # and even just "jorian" all find "Burssens, Jorian". Each token must
        # appear (AND), so extra tokens narrow rather than widen the result.
        case search_tokens(query) do
          [] ->
            []

          tokens ->
            where =
              Enum.reduce(tokens, dynamic(true), fn tok, acc ->
                pattern = "%" <> tok <> "%"
                dynamic([f], ^acc and like(f.name, ^pattern))
              end)

            Repo.all(
              from f in FidePlayer,
                where: ^where,
                order_by: [asc: is_nil(f.standard_rating), desc: f.standard_rating],
                limit: 20
            )
        end
    end
  end

  # Split a free-text name query into LIKE-safe tokens: split on commas and
  # whitespace, strip the LIKE wildcards `%`/`_`, drop empties.
  defp search_tokens(query) do
    query
    |> String.split(~r/[,\s]+/, trim: true)
    |> Enum.map(&String.replace(&1, ~r/[%_]/, ""))
    |> Enum.reject(&(&1 == ""))
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
