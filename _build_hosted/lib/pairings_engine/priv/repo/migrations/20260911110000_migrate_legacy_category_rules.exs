defmodule PairingsEngine.Repo.Migrations.MigrateLegacyCategoryRules do
  @moduledoc """
  Converts every tournament's `category_rules` from the legacy
  `"kind"`/`"value"` shape to the new condition-set shape (`"rating_from"` /
  `"rating_below"` / `"age_from"` / `"age_below"` / `"women"`) - see
  `PairingsEngine.Tournaments.Tournament`'s field doc for the new shape and
  `PairingsEngine.CategoryRules.migrate_legacy_rules/2` for the conversion
  itself, including the tightest-per-kind-collapse-as-bands reasoning that
  makes it more than a value rename.

  ## Why this calls application code, against this repo's own precedent

  `add_public_slug_to_tournaments.exs` and `add_pairing_display_board.exs`
  both backfill with raw table queries ONLY, deliberately not calling the
  application module that computes the equivalent value live - so a replay
  of this migration years from now, after that module has since changed,
  cannot silently start producing a different result than it did the day it
  ran.

  That precedent is for backfilling a value the application keeps
  RECOMPUTING going forward (a slug, a display board) - drift there would
  be silent because nothing else pins the old value down. A legacy
  category rule is different: FIDE's age-on-1-January arithmetic (`year -
  birth_year - 1`) and the four legacy `"kind"`s' own definitions are
  historical facts about a format this application no longer writes, not a
  live computation anything keeps re-deriving. `PairingsEngine.CategoryRules`
  and `PairingsEngine.TournamentImport` (an older backup file carries the
  same legacy shape at the door) BOTH need this exact conversion - the
  tightest-per-kind collapse, re-expressed as mutually exclusive bands with
  category-order tie-breaks - and reimplementing that in raw SQL here would
  not avoid the drift risk the precedent worries about, it would introduce
  a guaranteed second implementation to drift FROM the real one. One
  function, asserted never to change after this migration ships (the same
  contract a frozen dialect parser like `SwarImport`'s already keeps for an
  old file format), is the smaller risk.

  Self-contained schema-wise regardless: no `Tournament` struct or
  changeset here, only raw JSON text read and written back through
  `repo()`, same as the other backfills.
  """
  use Ecto.Migration

  import Ecto.Query

  alias PairingsEngine.CategoryRules

  def up do
    repo = repo()

    rows =
      repo.all(
        from(t in "tournaments",
          where: t.category_rules != "{}" and t.category_rules != "",
          select: {t.id, t.categories, t.category_rules}
        )
      )

    Enum.each(rows, &migrate_row(repo, &1))
  end

  defp migrate_row(repo, {id, categories_json, rules_json}) do
    with {:ok, categories} <- decode_list(categories_json),
         {:ok, rules} when map_size(rules) > 0 <- decode_map(rules_json) do
      migrated = CategoryRules.migrate_legacy_rules(rules, categories)

      if migrated != rules do
        repo.update_all(
          from(t in "tournaments", where: t.id == ^id),
          set: [category_rules: Jason.encode!(migrated)]
        )
      end
    end
  end

  defp decode_list(nil), do: {:ok, []}
  defp decode_list(json), do: with({:ok, list} <- Jason.decode(json), do: {:ok, List.wrap(list)})

  defp decode_map(nil), do: {:ok, %{}}
  defp decode_map(json), do: with({:ok, %{} = map} <- Jason.decode(json), do: {:ok, map})

  # No sensible inverse: a legacy rule that got banded (its own value plus a
  # neighbour's cap) cannot be told apart, after the fact, from one an
  # arbiter typed directly in the new shape with the same two keys. Nothing
  # is lost going forward either way - `auto_assign_categories/1` reads
  # whatever shape is actually stored, and this migration only ever adds
  # keys to an existing legacy rule, never removes a category or a player
  # assignment.
  def down, do: :ok
end
