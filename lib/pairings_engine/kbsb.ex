defmodule PairingsEngine.Kbsb do
  @moduledoc "Local copy of the Belgian national (KBSB/FRBE) rating list: search + import."

  import Ecto.Query
  alias PairingsEngine.Repo
  alias PairingsEngine.Kbsb.KbsbPlayer

  @doc """
  Looks a player up by national ID (exact match) or by last-name prefix,
  mirroring `PairingsEngine.Fide.search/1`'s query shape so the two feel
  the same in the UI.
  """
  def search(query) when is_binary(query) do
    query = String.trim(query)

    cond do
      query == "" ->
        []

      match = Repo.get(KbsbPlayer, query) ->
        [match]

      String.length(query) < 2 ->
        []

      true ->
        # Match every token (whitespace/comma separated) against either the
        # last OR first name, in any order — so "burssens jorian", "jorian
        # burssens", "burssens, jorian" and just "jorian" all find the player.
        case search_tokens(query) do
          [] ->
            []

          tokens ->
            where =
              Enum.reduce(tokens, dynamic(true), fn tok, acc ->
                pattern = "%" <> tok <> "%"

                dynamic(
                  [k],
                  ^acc and (like(k.last_name, ^pattern) or like(k.first_name, ^pattern))
                )
              end)

            Repo.all(
              from k in KbsbPlayer,
                where: ^where,
                order_by: [asc: is_nil(k.national_rating), desc: k.national_rating],
                limit: 20
            )
        end
    end
  end

  defp search_tokens(query) do
    query
    |> String.split(~r/[,\s]+/, trim: true)
    |> Enum.map(&String.replace(&1, ~r/[%_]/, ""))
    |> Enum.reject(&(&1 == ""))
  end

  @doc "Exact national-ID lookup, used by the player-registration autofill."
  def find_by_national_id(nil), do: nil
  def find_by_national_id(""), do: nil

  def find_by_national_id(national_id) when is_binary(national_id),
    do: Repo.get(KbsbPlayer, national_id)

  @doc """
  Looks up a KBSB row by FIDE ID, used to enrich a FIDE-database pick with
  the player's Belgian national ID/rating when one is on file.
  """
  def find_by_fide_id(nil), do: nil

  def find_by_fide_id(fide_id) when is_integer(fide_id) do
    Repo.one(from k in KbsbPlayer, where: k.fide_id == ^fide_id, limit: 1)
  end

  def player_count, do: Repo.aggregate(KbsbPlayer, :count)

  def last_sync do
    case Repo.query!("SELECT value FROM meta WHERE key = 'kbsb_last_sync'").rows do
      [[value]] -> value
      _ -> nil
    end
  end

  def put_last_sync do
    Repo.query!(
      "INSERT INTO meta (key, value) VALUES ('kbsb_last_sync', datetime('now')) " <>
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value"
    )
  end
end
