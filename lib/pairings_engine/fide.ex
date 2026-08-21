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
        # comma-separated token as a name token (any order), so "burssens,
        # jorian", "burssens jorian", "jorian burssens" and even just "jorian"
        # all find "Burssens, Jorian". Served by the FTS5 index (see the
        # `fide_players_fts` migration) so it stays fast over ~1.9M rows;
        # falls back to a plain LIKE scan if the FTS table isn't there yet.
        case search_tokens(query) do
          [] -> []
          tokens -> fts_search(tokens) || like_search(tokens)
        end
    end
  end

  # Split a free-text name query into tokens: split on commas and whitespace,
  # keep only letters/digits (so LIKE wildcards and FTS operators can't leak
  # in), drop empties.
  defp search_tokens(query) do
    query
    |> String.split(~r/[,\s]+/, trim: true)
    |> Enum.map(&String.replace(&1, ~r/[^\p{L}\p{N}]/u, ""))
    |> Enum.reject(&(&1 == ""))
  end

  # FTS5 prefix match, AND-ed across tokens (`"jorian"* "burssens"*`), then load
  # + rank the matched players. Returns nil (not []) if the FTS table is
  # missing, so the caller can fall back - an empty *result* is a real answer.
  defp fts_search(tokens) do
    match = Enum.map_join(tokens, " ", &(~s("#{&1}") <> "*"))

    case Repo.query(
           "SELECT fide_id FROM fide_players_fts WHERE fide_players_fts MATCH ? LIMIT 40",
           [match]
         ) do
      {:ok, %{rows: rows}} ->
        ids = Enum.map(rows, fn [id] -> id end)

        Repo.all(
          from f in FidePlayer,
            where: f.fide_id in ^ids,
            order_by: [asc: is_nil(f.standard_rating), desc: f.standard_rating],
            limit: 20
        )

      {:error, _} ->
        nil
    end
  end

  defp like_search(tokens) do
    where =
      Enum.reduce(tokens, dynamic(true), fn tok, acc ->
        dynamic([f], ^acc and like(f.name, ^("%" <> tok <> "%")))
      end)

    Repo.all(
      from f in FidePlayer,
        where: ^where,
        order_by: [asc: is_nil(f.standard_rating), desc: f.standard_rating],
        limit: 20
    )
  end

  def player_count, do: Repo.aggregate(FidePlayer, :count)

  @doc """
  The FIDE player with `fide_id`, or `nil` - accepts the id as an integer or
  as the string an `officials` map stores it as. `nil` for anything that isn't
  an id at all, so callers prefilling a form from stored data don't have to
  pre-validate it.
  """
  def get_player(fide_id) when is_integer(fide_id), do: Repo.get(FidePlayer, fide_id)

  def get_player(fide_id) do
    case Integer.parse(to_string(fide_id)) do
      {id, ""} -> Repo.get(FidePlayer, id)
      _ -> nil
    end
  end

  @doc """
  The FIDE rating to actually use for a tournament of the given cadence
  classification (`tournament.standard` - `"standard"`/`"rapid"`/`"blitz"`,
  same field `PairingsEngine.RateOfPlay` reads): `fide_player`'s rating for
  that specific list, falling back to the Standard rating when the player
  has no rating in the tournament's own list (an untitled rapid/blitz
  newcomer with only a Standard rating is the common case this covers -
  FIDE itself only publishes a Rapid/Blitz rating once a player has enough
  rated games in that list). Anything other than `"rapid"`/`"blitz"`
  (including `""`/`nil`) reads the Standard rating directly, mirroring
  `RateOfPlay.list_for/1`'s own default. `nil` in, `nil` out.

  FIDE's own list uses `0`, not a blank field, for "no rating in this list" -
  so the fallback has to treat `0` the same as `nil`. Plain `||` wouldn't:
  `0` is truthy in Elixir, so `0 || standard_rating` would return the `0`
  instead of falling through, and an unrated-in-that-list player would show
  as literal 0 Elo instead of their real Standard rating.
  """
  def rating_for_tempo(nil, _standard), do: nil

  def rating_for_tempo(%FidePlayer{} = fide_player, standard) do
    case standard do
      "rapid" -> present(fide_player.rapid_rating) || fide_player.standard_rating
      "blitz" -> present(fide_player.blitz_rating) || fide_player.standard_rating
      _ -> fide_player.standard_rating
    end
  end

  defp present(nil), do: nil
  defp present(0), do: nil
  defp present(rating), do: rating

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
