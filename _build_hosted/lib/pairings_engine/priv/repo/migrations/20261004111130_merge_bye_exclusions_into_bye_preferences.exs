defmodule PairingsEngine.Repo.Migrations.MergeByeExclusionsIntoByePreferences do
  @moduledoc """
  "No pairing-allocated bye for chosen players" (`bel_bye_exclusions`, in the
  Belgian pack) and "Bye preferences" (`bye_preferences`, in no pack) were two
  switches for one thing: the exclusion is the strongest bye preference, and
  no more Belgian than the rest. Since 0.74.2 the single `bye_preferences`
  switch shows both controls.

  An account that had the exclusion switched on keeps its button: it gets
  `bye_preferences` (if it did not have it already), and the old key is
  dropped. `users.features` is a JSON text array (ecto_sqlite3's
  `{:array, :string}`), so the rewrite is done row by row in Elixir rather
  than with SQLite's JSON functions. Stored exclusions on players are not
  touched: the switch only ever gated the control.
  """
  use Ecto.Migration

  import Ecto.Query

  def up do
    repo().all(
      from(u in "users",
        where: like(u.features, "%bel_bye_exclusions%"),
        select: {u.id, u.features}
      )
    )
    |> Enum.each(fn {id, json} ->
      features = Jason.decode!(json || "[]")

      merged =
        features
        |> Enum.reject(&(&1 == "bel_bye_exclusions"))
        |> then(fn rest ->
          if "bye_preferences" in rest, do: rest, else: rest ++ ["bye_preferences"]
        end)

      repo().update_all(from(u in "users", where: u.id == ^id),
        set: [features: Jason.encode!(merged)]
      )
    end)
  end

  # Not reversible exactly (an account that had both keys looks the same as
  # one that had only `bye_preferences`), and nothing needs it to be: the old
  # key is still honoured by the player form if it ever comes back.
  def down, do: :ok
end
