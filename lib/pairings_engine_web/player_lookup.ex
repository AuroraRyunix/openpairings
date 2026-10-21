defmodule PairingsEngineWeb.PlayerLookup do
  @moduledoc """
  Adding a player from a list: the search and what a pick fills in.

  The Players page's add form and the Manubrium app's player search
  (`PairingsEngineWeb.ManubriumApi.PlayerController`) both come through
  here, so a player added from a phone carries exactly what the same pick
  on the desk would have put in the form: the FIDE record's name, title,
  sex and the rating of the tournament's main list
  (`PairingsEngine.RatingLists`), and, with the Belgian lookup on, the
  national id, rating and club of the matching member.

  Nothing here writes. The add itself is `DeskActions.create_player/3`, for
  both callers.
  """

  alias PairingsEngine.{Features, Fide, RatingLists}
  alias PairingsEngine.Federations.BEL.{Member, Members}
  alias PairingsEngine.Fide.FidePlayer
  alias PairingsEngine.Tournaments.Player

  @lookup_feature "bel_player_lookup"

  @doc "The feature key that switches the Belgian member lookup on."
  def lookup_feature, do: @lookup_feature

  @doc """
  Whether the Belgian member lookup is on for `scope`'s account - the
  switch the Players page reads before it searches the national list.
  """
  def bel_lookup?(scope), do: Features.enabled?(scope, @lookup_feature)

  @doc """
  Whether a phone should be offered the Belgian list at all: the lookup is
  on for the account AND this installation has a list to search. A switch
  over an empty table would only ever answer "nobody".
  """
  def bel_available?(scope), do: bel_lookup?(scope) and Members.player_count() > 0

  @doc """
  The add form's search for `query`: `%{fide: [...], bel: [...], custom: [...]}`.

  With the Belgian lookup on (`bel?`), members come too, and a FIDE hit for
  a member already listed is left out of `fide`, since picking the member
  pulls the FIDE details in anyway. A member whose KBSB row carries no FIDE
  id is still the same person as a Belgian FIDE entry with the same name
  and birth year: that FIDE id is attached to the member's hit and the FIDE
  hit is left out. Only a single, exact match counts.
  """
  def search(tournament, query, bel?) do
    fide = query |> Fide.search() |> Enum.uniq_by(& &1.fide_id)

    bel =
      if bel?,
        do:
          query
          |> Members.search()
          |> Enum.uniq_by(& &1.national_id)
          |> Enum.take(10)
          |> attach_fide_ids(fide),
        else: []

    covered = bel |> Enum.map(& &1.fide_id) |> Enum.reject(&is_nil/1) |> MapSet.new()

    custom =
      tournament
      |> RatingLists.sequence()
      |> RatingLists.search_custom(query)
      |> Enum.reject(fn {_list, e} ->
        e.fide_id && Enum.any?(fide, &(&1.fide_id == e.fide_id))
      end)

    %{
      fide: Enum.reject(fide, &MapSet.member?(covered, &1.fide_id)),
      bel: bel,
      custom: custom
    }
  end

  @doc """
  The form values a FIDE pick fills in, with `rating_values` (by default
  the main list's rating, `RatingLists.main_values/2`) and, with the
  Belgian lookup on (`bel?`), the matching member's national details.
  """
  def fide_values(tournament, %FidePlayer{} = fp, bel?, rating_values \\ nil) do
    rating_values =
      rating_values || RatingLists.main_values(fp, RatingLists.sequence(tournament))

    %{
      "name" => fp.name,
      "title" => fp.title,
      "fide_id" => fp.fide_id,
      "federation" => fp.federation,
      "birth_year" => fp.birth_year,
      "sex" => Player.normalize_sex(fp.sex)
    }
    |> Map.merge(rating_values)
    |> merge_member_by_fide_id(fp.fide_id, bel?)
  end

  @doc """
  The form values a member pick fills in: the national details from the
  KBSB list and, when the member has a FIDE id, the FIDE name, title,
  rating and sex from the FIDE list - the values a FIDE pick would give.
  """
  def bel_values(tournament, %Member{} = kp) do
    fp = kp.fide_id && Fide.get_player(kp.fide_id)

    fide_values =
      if fp,
        do:
          %{
            "title" => fp.title,
            "fide_id" => fp.fide_id,
            "sex" => Player.normalize_sex(fp.sex)
          }
          |> Map.merge(RatingLists.fide_values(fp, RatingLists.sequence(tournament))),
        else: %{"fide_id" => kp.fide_id}

    %{
      "name" => Member.full_name(kp),
      "national_id" => kp.national_id,
      "national_rating" => kp.national_rating,
      "club" => kp.club_name,
      "club_number" => kp.club_number,
      "birth_year" => kp.birth_year
    }
    |> Map.merge(fide_values)
    |> put_if_blank("federation", Members.fide_federation(kp))
    |> put_member_sex(kp)
  end

  # Picking a FIDE result also fills in the matching KBSB row (if any) - the
  # two lists are cross-referenced by FIDE id. The same switch governs it.
  defp merge_member_by_fide_id(values, _fide_id, false), do: values

  defp merge_member_by_fide_id(values, fide_id, true) do
    case Members.find_by_fide_id(fide_id) do
      nil ->
        values

      kp ->
        values
        |> Map.merge(%{
          "national_id" => kp.national_id,
          "national_rating" => kp.national_rating,
          "club" => kp.club_name,
          "club_number" => kp.club_number
        })
        |> put_member_sex(kp)
    end
  end

  @doc """
  The FIDE list's sex when the member has a FIDE record that states one -
  it is what the rating report is checked against - and otherwise the
  national list's own.
  """
  def put_member_sex(values, %Member{sex: sex}) when sex in ~w(m w) do
    if values["sex"] in ["m", "w"], do: values, else: Map.put(values, "sex", sex)
  end

  def put_member_sex(values, _member), do: values

  @doc "Puts `value` under `key` unless `map` already has a non-blank one."
  def put_if_blank(map, _key, nil), do: map

  def put_if_blank(map, key, value) do
    case Map.get(map, key) do
      v when v in [nil, ""] -> Map.put(map, key, value)
      _ -> map
    end
  end

  defp attach_fide_ids(members, fide) do
    by_key =
      fide
      |> Enum.filter(&(&1.federation == "BEL" and is_integer(&1.birth_year)))
      |> Enum.group_by(&{search_key(&1.name), &1.birth_year})

    Enum.map(members, fn
      %{fide_id: nil, birth_year: year} = member when is_integer(year) ->
        case Map.get(by_key, {search_key(Member.full_name(member)), year}) do
          [single] -> %{member | fide_id: single.fide_id}
          _none_or_ambiguous -> member
        end

      member ->
        member
    end)
  end

  # "Lastname, First", "LASTNAME First" and the accented spelling alike.
  defp search_key(name) do
    name
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z]+/, " ")
    |> String.trim()
  end
end
