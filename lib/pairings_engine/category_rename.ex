defmodule PairingsEngine.CategoryRename do
  @moduledoc """
  Renames one category of a tournament everywhere its name is written.

  A category is a plain string, copied into five places: the tournament's
  `categories` list, the `category_rules` and `category_prizes` maps keyed by
  it, the two-axis SWAR list `swar_category_axis2`, and every player's
  `categories` tags and `category` override. Renaming only the list would
  orphan the rest (rules gone silent, prizes forgotten, players quietly in no
  category at all), so this changes all of it or none of it, after a pinned
  restore point.

  `{:ok, tournament, players_changed}` or
  `{:error, :blank | :too_long | :unchanged | :taken | :not_found | term}`.
  """
  import Ecto.Query

  alias PairingsEngine.{Repo, Snapshots, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  @trigger "category.renamed"

  def rename(%Tournament{} = tournament, old, new, scope) when is_binary(new) do
    new = String.trim(new)
    categories = tournament.categories || []

    cond do
      old not in categories ->
        {:error, :not_found}

      new == "" ->
        {:error, :blank}

      String.length(new) > 80 ->
        {:error, :too_long}

      new == old ->
        {:error, :unchanged}

      new in categories ->
        {:error, :taken}

      true ->
        do_rename(tournament, old, new, scope)
    end
  end

  defp do_rename(tournament, old, new, scope) do
    # The safety net first; if it cannot be made the rename does not happen,
    # because this one rewrites the roster.
    case Snapshots.capture(tournament, @trigger, scope,
           summary: "Before renaming category #{old} to #{new}",
           pinned: true
         ) do
      {:ok, _} -> write(tournament, old, new)
      {:error, _} -> {:error, :no_restore_point}
    end
  end

  defp write(tournament, old, new) do
    attrs = %{
      "categories" => Enum.map(tournament.categories, &swap(&1, old, new)),
      "category_rules" => rekey(tournament.category_rules, old, new),
      "category_prizes" => rekey(tournament.category_prizes, old, new),
      "swar_category_axis2" => Enum.map(tournament.swar_category_axis2 || [], &swap(&1, old, new))
    }

    updates =
      from(p in Player, where: p.tournament_id == ^tournament.id)
      |> Repo.all()
      |> Enum.filter(&(old in (&1.categories || []) or &1.category == old))
      |> Enum.map(fn p ->
        {p,
         %{
           categories: Enum.map(p.categories || [], &swap(&1, old, new)),
           category: swap(p.category, old, new)
         }}
      end)

    with {:ok, tournament} <- Tournaments.update_tournament(tournament, attrs),
         {:ok, _} <- Tournaments.bulk_update_players(tournament.id, updates) do
      {:ok, tournament, length(updates)}
    end
  end

  defp swap(name, old, new), do: if(name == old, do: new, else: name)

  defp rekey(map, old, new) do
    case Map.pop(map || %{}, old) do
      {nil, rest} -> rest
      {value, rest} -> Map.put(rest, new, value)
    end
  end
end
