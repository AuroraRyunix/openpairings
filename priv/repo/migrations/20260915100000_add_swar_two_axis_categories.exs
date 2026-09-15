defmodule PairingsEngine.Repo.Migrations.AddSwarTwoAxisCategories do
  @moduledoc """
  SWAR's `[CATEGORIES]` block can define a category as the product of TWO
  axes (age-then-rating or rating-then-age), each a list of numeric bounds.
  This app models one axis as one set of named categories - see
  `docs/swar-import.md`'s "Categories: two axes, two tag sets" section - and
  a player imported from a two-axis file carries both axis tags.

  `swar_category_type` and `swar_category_axis2` exist purely so
  `SwarExport` can write a re-imported tournament's categories back onto the
  same two `[CATEGORIES]` columns SWAR read them from, instead of collapsing
  everything into `value1` the way a plain OpenPairings-authored category
  list does:

    * `swar_category_type` - the SWAR `Categorie` type integer (3 or 4) when
      `categories` came from a two-axis import; nil otherwise (a plain
      single-axis list, or a tournament with no SWAR provenance at all).
    * `swar_category_axis2` - the subset (and order) of `categories` that
      came from the file's `value2` column. `categories -- swar_category_axis2`,
      in order, is axis 1.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :swar_category_type, :integer
      add :swar_category_axis2, {:array, :string}, default: [], null: false
    end
  end
end
