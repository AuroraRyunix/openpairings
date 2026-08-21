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
        # last OR first name, in any order - so "burssens jorian", "jorian
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

  @doc """
  Normalized form used to match a typed player name against the list:
  lower-cased, accents stripped, and every run of non-alphanumerics
  collapsed to one space. `"Hendricks, Björn"` and `"hendricks  BJORN"`
  both become `"hendricks bjorn"`.

  Folding accents matters more here than it looks. The KBSB list spells
  names with them and an arbiter registering players at a desk usually
  does not, so an exact comparison would miss precisely the Belgian names
  this exists for.
  """
  def normalize_name(nil), do: ""

  def normalize_name(name) do
    name
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036F}]/u, "")
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.trim()
  end

  @doc """
  Builds `%{normalize_name(full_name) => [KbsbPlayer]}` across the whole
  list, for callers matching many players in one go (see
  `PairingsEngine.ClubRefresh`).

  Deliberately one query and one pass rather than a lookup per player: the
  list is tens of thousands of rows but a tournament is a few hundred
  players, and there is no index that could serve an accent-folded
  comparison anyway - SQLite's `lower()` doesn't fold accents.

  The value is a LIST because names are not unique. Callers must decide
  what to do with more than one; this function refuses to pick for them.

  Deceased members are excluded. The API sync mirrors the roster unfiltered
  on purpose (see the AddKbsbPlayerStatusFlags migration), which puts the
  decision here - and a *name* is exactly the wrong key to resolve onto a
  dead member with, because the living player sitting at the board is the
  one being registered. Exact id lookups (`find_by_national_id/1`,
  `find_by_fide_id/1`) deliberately still find them: an arbiter who types a
  matricule wants an answer, not a silent miss. Rows from the older
  file-upload path have `died: nil` and are kept.
  """
  def name_index do
    from(k in KbsbPlayer, where: is_nil(k.died) or k.died == false)
    |> Repo.all()
    |> Enum.group_by(&normalize_name(KbsbPlayer.full_name(&1)))
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
