defmodule PairingsEngine.RatingLists do
  @moduledoc """
  Rating lists and the sequence a tournament reads them in (VCL4THP 117-129).

  ## Lists

    * the FIDE lists - `fide_standard`, `fide_rapid`, `fide_blitz`, and the two
      effective ones: `effective_rapid` is the Rapid rating, or the Standard
      one for a player without it, and `effective_blitz` likewise
    * `national` - the national list synced from the federation (the KBSB list)
    * `custom:<id>` - a list an administrator loaded from a CSV file
      (`import_list/2`). Custom lists are machine-wide, like the FIDE and
      national lists: a tournament's sequence names them, and every arbiter and
      collaborator on the machine sees the same ones. Loading and deleting them
      is for administrators (the Rating lists page).

  ## The sequence

  A tournament has an ordered sequence of those lists
  (`tournaments.rating_list_sequence`). Without a stored one it has the
  default for its rate of play, which follows the rate of play if that changes:

    * Standard: FIDE Standard, FIDE Rapid, FIDE Blitz
    * Rapid: Effective Rapid, FIDE Blitz
    * Blitz: Effective Blitz, FIDE Rapid

  The first list is the main list. When a player is added, the rating in the
  main list is entered; ratings the player has in the other lists of the
  sequence are shown and can be picked instead. A FIDE list fills the FIDE
  rating, the national and custom lists fill the national rating.

  The consistency check and the bulk refresh read the FIDE rating from the
  first FIDE list of the sequence (`fide_entry/1`).

  This chooses where a rating is read from when it is entered or refreshed. It
  does not touch how the pairing rating is chosen from the FIDE and national
  ratings already on a player.
  """

  import Ecto.Query

  alias PairingsEngine.Federations.BEL.Members
  alias PairingsEngine.Fide
  alias PairingsEngine.Fide.FidePlayer
  alias PairingsEngine.RatingLists.{Csv, CustomEntry, CustomList}
  alias PairingsEngine.Repo

  @fide_entries ~w(fide_standard fide_rapid fide_blitz effective_rapid effective_blitz)

  @doc "The FIDE-list entries, in the order an editor offers them."
  def fide_entries, do: @fide_entries

  ## ---------- the sequence ----------

  @doc "The default sequence for a rate of play (`tournament.standard`)."
  def default_sequence("rapid"), do: ["effective_rapid", "fide_blitz"]
  def default_sequence("blitz"), do: ["effective_blitz", "fide_rapid"]
  def default_sequence(_), do: ["fide_standard", "fide_rapid", "fide_blitz"]

  @doc "Whether `entry` is a well-formed list name (a custom list is not checked for existing)."
  def valid_entry?(entry) when entry in @fide_entries or entry == "national", do: true
  def valid_entry?("custom:" <> id), do: custom_id(id) != nil
  def valid_entry?(_), do: false

  defp custom_id(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 and n < 1_000_000_000 -> n
      _ -> nil
    end
  end

  @doc """
  The sequence in force for `tournament`: its own, without entries for custom
  lists that no longer exist, or the default for its rate of play.
  """
  def sequence(tournament) do
    stored = Map.get(tournament, :rating_list_sequence)

    cleaned =
      if is_list(stored) do
        existing = custom_lists() |> MapSet.new(&"custom:#{&1.id}")

        Enum.filter(stored, fn entry ->
          valid_entry?(entry) and (not custom?(entry) or MapSet.member?(existing, entry))
        end)
      else
        []
      end

    if cleaned == [], do: default_sequence(Map.get(tournament, :standard)), else: cleaned
  end

  @doc "Whether the tournament uses a sequence of its own rather than the default."
  def custom_sequence?(tournament),
    do: sequence(tournament) != default_sequence(tournament.standard)

  def custom?("custom:" <> _), do: true
  def custom?(_), do: false

  @doc "The first FIDE list of `sequence`: the one the FIDE rating is read from when refreshing."
  def fide_entry(sequence), do: Enum.find(sequence, &(&1 in @fide_entries)) || "fide_standard"

  @doc "A name for `entry`; `names` is `custom_names/0` for custom lists."
  def label(entry, names \\ %{})
  def label("fide_standard", _), do: "FIDE Standard"
  def label("fide_rapid", _), do: "FIDE Rapid"
  def label("fide_blitz", _), do: "FIDE Blitz"
  def label("effective_rapid", _), do: "Effective Rapid"
  def label("effective_blitz", _), do: "Effective Blitz"
  def label("national", _), do: "National"

  def label("custom:" <> id, names),
    do: Map.get(names, custom_id(id) || 0, "Custom list #{id}")

  @doc "`%{id => name}` of the custom lists."
  def custom_names, do: Map.new(custom_lists(), &{&1.id, &1.name})

  ## ---------- ratings of a FIDE record in each list ----------

  @doc """
  The rating a FIDE record has in a FIDE-list `entry`, with the list it came
  from (`"standard" | "rapid" | "blitz"`): `{rating, list}`, or `nil`. An
  effective list reports the list it actually read.
  """
  def fide_rating(nil, _entry), do: nil

  def fide_rating(%FidePlayer{} = fp, "fide_standard"), do: wrap(fp.standard_rating, "standard")
  def fide_rating(%FidePlayer{} = fp, "fide_rapid"), do: wrap(present(fp.rapid_rating), "rapid")
  def fide_rating(%FidePlayer{} = fp, "fide_blitz"), do: wrap(present(fp.blitz_rating), "blitz")

  def fide_rating(%FidePlayer{} = fp, "effective_rapid"),
    do: fide_rating(fp, "fide_rapid") || fide_rating(fp, "fide_standard")

  def fide_rating(%FidePlayer{} = fp, "effective_blitz"),
    do: fide_rating(fp, "fide_blitz") || fide_rating(fp, "fide_standard")

  def fide_rating(_fp, _entry), do: nil

  defp wrap(nil, _), do: nil
  defp wrap(rating, list), do: {rating, list}

  defp present(r) when is_integer(r) and r > 0, do: r
  defp present(_), do: nil

  @doc """
  The FIDE rating a refresh or a registration takes from `fide_player` under
  `sequence`: `{rating, list}` or `nil`.
  """
  def main_fide_rating(fide_player, sequence),
    do: fide_rating(fide_player, fide_entry(sequence))

  @doc """
  What a FIDE record has in each list of `sequence`, in order:
  `[%{entry:, label:, rating:, lane:, list:}]`. `rating` is `nil` for a list the
  player is not in; `lane` is `:fide` or `:national` (the player field the
  rating fills); `list` is the FIDE list a FIDE rating was read from.
  """
  def ratings_for(%FidePlayer{} = fp, sequence) do
    names = custom_names()

    Enum.map(sequence, fn entry ->
      {rating, list, lane} =
        cond do
          entry in @fide_entries ->
            case fide_rating(fp, entry) do
              {r, l} -> {r, l, :fide}
              nil -> {nil, nil, :fide}
            end

          entry == "national" ->
            {national_rating(fp.fide_id), nil, :national}

          true ->
            {custom_rating(entry, fp.fide_id), nil, :national}
        end

      %{
        entry: entry,
        label: label(entry, names),
        rating: present(rating),
        lane: lane,
        list: list
      }
    end)
  end

  defp national_rating(nil), do: nil

  defp national_rating(fide_id) do
    case Members.find_by_fide_id(fide_id) do
      %{national_rating: r} -> present(r)
      _ -> nil
    end
  end

  defp custom_rating("custom:" <> id, fide_id) when is_integer(fide_id) do
    case custom_id(id) do
      nil ->
        nil

      list_id ->
        Repo.one(
          from e in CustomEntry,
            where: e.list_id == ^list_id and e.fide_id == ^fide_id,
            select: e.rating,
            limit: 1
        )
        |> present()
    end
  end

  defp custom_rating(_, _), do: nil

  @doc """
  The form values a pick of `rated` (one element of `ratings_for/2`) puts on
  the player: the FIDE rating with where it came from, or the national rating.
  A FIDE list without a rating for the player clears the FIDE rating (the
  player is not rated there); a national or custom list without one changes
  nothing.
  """
  def values(%{lane: :fide, rating: nil}) do
    %{
      "fide_rating" => nil,
      "fide_rating_source" => "",
      "fide_rating_period" => "",
      "fide_rating_listed" => ""
    }
  end

  def values(%{lane: :national, rating: nil}), do: %{}

  def values(%{lane: :fide, rating: rating, list: list}) do
    %{
      "fide_rating" => rating,
      "fide_rating_source" => list,
      "fide_rating_period" => Fide.list_period() || "",
      "fide_rating_listed" => rating
    }
  end

  def values(%{lane: :national, rating: rating}), do: %{"national_rating" => rating}

  @doc """
  The values the first list of `sequence` gives a FIDE record: what is entered
  when the player is added (see `values/1`).
  """
  def main_values(%FidePlayer{} = fp, sequence) do
    case ratings_for(fp, [hd(sequence)]) do
      [%{lane: :fide} = main] -> values(main)
      [main] -> Map.merge(values(%{lane: :fide, rating: nil}), values(main))
      [] -> %{}
    end
  end

  @doc """
  The FIDE rating values (with where they came from) of the first FIDE list of
  `sequence`, whatever the main list is - for the paths that only deal with
  the FIDE rating.
  """
  def fide_values(%FidePlayer{} = fp, sequence) do
    case ratings_for(fp, [fide_entry(sequence)]) do
      [main] -> values(main)
      [] -> %{}
    end
  end

  @doc """
  The ratings of a FIDE record in the lists of `sequence` other than the main
  one, only those it has one in: the ones a user can pick instead.
  """
  def other_ratings(%FidePlayer{} = fp, sequence) do
    case sequence do
      [_main | rest] when rest != [] ->
        fp |> ratings_for(rest) |> Enum.filter(& &1.rating)

      _ ->
        []
    end
  end

  ## ---------- custom lists ----------

  @doc "All custom lists, by name."
  def custom_lists,
    do: Repo.all(from l in CustomList, order_by: [asc: fragment("lower(?)", l.name)])

  def get_list(id), do: Repo.get(CustomList, id)

  @doc "The lists a sequence can be built from, as `{entry, label}`."
  def available_entries do
    names = custom_names()

    Enum.map(@fide_entries ++ ["national"], &{&1, label(&1)}) ++
      for {id, name} <- Enum.sort_by(names, &String.downcase(elem(&1, 1))),
          do: {"custom:#{id}", name}
  end

  @doc """
  Loads `rows` (from `Csv.parse/1`) as the list called `name`. A list of that
  name (case aside) is replaced, keeping its id, so sequences naming it stay
  valid. `{:ok, list, replaced?}` or `{:error, message}`.
  """
  def import_list(name, rows) when is_binary(name) and is_list(rows) do
    name = String.trim(name)

    cond do
      name == "" ->
        {:error, "Give the list a name."}

      String.length(name) > 80 ->
        {:error, "The name is longer than 80 characters."}

      rows == [] ->
        {:error, "The file has no players."}

      length(rows) > Csv.max_rows() ->
        {:error, "The file has more than #{Csv.max_rows()} players."}

      true ->
        existing = existing_list(name)

        Repo.transaction(fn ->
          list =
            case existing do
              nil ->
                Repo.insert!(%CustomList{name: name, entry_count: length(rows)})

              %CustomList{} = l ->
                Repo.delete_all(from e in CustomEntry, where: e.list_id == ^l.id)

                l
                |> Ecto.Changeset.change(entry_count: length(rows), name: name)
                |> Repo.update!()
            end

          rows
          |> Enum.map(&Map.put(&1, :list_id, list.id))
          |> Enum.chunk_every(500)
          |> Enum.each(&Repo.insert_all(CustomEntry, &1))

          {list, existing != nil}
        end)
        |> case do
          {:ok, {list, replaced?}} -> {:ok, list, replaced?}
          {:error, reason} -> {:error, inspect(reason)}
        end
    end
  end

  @doc "The custom list called `name` (case aside), or `nil`."
  def existing_list(name) do
    key = String.downcase(String.trim(name))
    Repo.one(from l in CustomList, where: fragment("lower(?)", l.name) == ^key, limit: 1)
  end

  @doc "Deletes a custom list and its players."
  def delete_list(id) do
    case get_list(id) do
      nil -> {:error, :not_found}
      list -> Repo.delete(list)
    end
  end

  @doc """
  Players of the custom lists in `sequence` matching a typed query (name
  tokens, or the list's own id), best-rated first: `[{list_name, %CustomEntry{}}]`.
  """
  def search_custom(sequence, query, limit \\ 10) when is_binary(query) do
    list_ids = for "custom:" <> id <- sequence, n = custom_id(id), do: n
    query = String.trim(query)

    if list_ids == [] or String.length(query) < 2 do
      []
    else
      names = custom_names()

      tokens =
        query
        |> String.split(~r/[,\s]+/, trim: true)
        |> Enum.map(&String.replace(&1, ~r/[\\%_]/, ""))
        |> Enum.reject(&(&1 == ""))

      # Only wildcards typed: no name can be meant (the id may still match).
      by_name =
        if tokens == [],
          do: dynamic(false),
          else:
            Enum.reduce(tokens, dynamic([e], e.list_id in ^list_ids), fn tok, acc ->
              dynamic([e], ^acc and like(e.name, ^("%" <> tok <> "%")))
            end)

      where = dynamic([e], ^by_name or (e.list_id in ^list_ids and e.ext_id == ^query))

      Repo.all(
        from e in CustomEntry,
          where: ^where,
          order_by: [asc: is_nil(e.rating), desc: e.rating, asc: e.name],
          limit: ^limit
      )
      |> Enum.map(&{Map.get(names, &1.list_id, ""), &1})
    end
  end

  def get_entry(id), do: Repo.get(CustomEntry, id)
end
